module Rpush
  module Daemon
    module Fcm
      # https://firebase.google.com/docs/cloud-messaging/server
      class Delivery < Rpush::Daemon::Delivery
        include MultiJsonHelper

        JSON_PRIVATE_KEY = Base64.strict_decode64(Settings.firebase.fcm_push_notification.base64_private_key)
        PROJECT_ID = Settings.firebase.fcm_push_notification.project_id
        AUTH_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging'.freeze
        SCOPE = 'https://www.googleapis.com/auth/firebase.messaging'.freeze
        ENDPOINT = "https://fcm.googleapis.com/v1/projects/#{PROJECT_ID}/messages:send".freeze

        def initialize(app, http, notification, batch)
          @app = app
          @http = http
          @notification = notification
          @batch = batch

          @uri = URI.parse(ENDPOINT)
        end

        def perform
          handle_response(do_post)
        rescue SocketError => error
          mark_retryable(@notification, Time.now + 10.seconds, error)
          raise
        rescue StandardError => error
          mark_failed(error)
          raise
        ensure
          @batch.notification_processed
        end

        protected

        def handle_response(response)
          case response.code.to_i
          when 200
            ok
          when 400
            bad_request(response)
          when 401
            unauthorized
          when 403
            sender_id_mismatch
          when 404
            unregistered(response)
          when 429
            too_many_requests
          when 500
            internal_server_error(response)
          when 502
            bad_gateway(response)
          when 503
            service_unavailable(response)
          when 500..599
            other_5xx_error(response)
          else
            fail Rpush::DeliveryError.new(response.code.to_i, @notification.id, Rpush::Daemon::HTTP_STATUS_CODES[response.code.to_i])
          end
        end

        def ok
          reflect(:fcm_delivered_to_recipient, @notification)
          mark_delivered
          log_info("#{@notification.id} sent to #{@notification.device_token}")
        end

        def bad_request(response)
          fail Rpush::DeliveryError.new(400, @notification.id, "FCM failed to handle the JSON request. (#{parse_error(response)})")
        end

        def unauthorized
          fail Rpush::DeliveryError.new(401, @notification.id, 'Unauthorized, Bearer token could not be validated.')
        end

        def sender_id_mismatch
          fail Rpush::DeliveryError.new(403, @notification.id, 'The sender ID was mismatched. It seems the device token is wrong.')
        end

        def unregistered(response)
          fail Rpush::DeliveryError.new(404, @notification.id, "Client was not registered for your app. (#{parse_error(response)})")
        end

        def too_many_requests
          fail Rpush::DeliveryError.new(429, @notification.id, 'Slow down. Too many requests were sent!')
        end

        def internal_server_error(response)
          retry_delivery(@notification, response)
          log_warn("FCM responded with an Internal Error. " + retry_message)
        end

        def bad_gateway(response)
          retry_delivery(@notification, response)
          log_warn("FCM responded with a Bad Gateway Error. " + retry_message)
        end

        def service_unavailable(response)
          retry_delivery(@notification, response)
          log_warn("FCM responded with an Service Unavailable Error. " + retry_message)
        end

        def other_5xx_error(response)
          retry_delivery(@notification, response)
          log_warn("FCM responded with a 5xx Error. " + retry_message)
        end

        def parse_error(response)
          error = multi_json_load(response.body)['error']
          puts "PARSED: #{error} #{error['message']}"
          "#{error['status']}: #{error['message']}"
        end

        def deliver_after_header(response)
          Rpush::Daemon::RetryHeaderParser.parse(response.header['retry-after'])
        end

        def retry_delivery(notification, response)
          time = deliver_after_header(response)
          if time
            mark_retryable(notification, time)
          else
            mark_retryable_exponential(notification)
          end
        end

        def retry_message
          "Notification #{@notification.id} will be retried after #{@notification.deliver_after.strftime('%Y-%m-%d %H:%M:%S')} (retry #{@notification.retries})."
        end

        def get_access_token # rubocop:todo Naming/AccessorMethodName
          credentials = Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: StringIO.new(JSON_PRIVATE_KEY),
            scope: AUTH_SCOPE
          )

          token_response = credentials.fetch_access_token!
          token_response['access_token']
        end

        def do_post
          token = get_access_token
          post = Net::HTTP::Post.new(@uri.path, 'Content-Type'  => 'application/json',
                                     'Authorization' => "Bearer #{token}")
          post.body = @notification.as_json.to_json
          @http.request(@uri, post)
        end
      end
    end
  end
end
