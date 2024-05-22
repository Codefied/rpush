module Rpush
  module Daemon
    module Fcm
      # https://firebase.google.com/docs/cloud-messaging/server
      class Delivery < Rpush::Daemon::Delivery
        include MultiJsonHelper

        # Assuming tokens are valid for 50 minutes
        TOKEN_VALID_FOR_SEC = 60 * 50
        AUTH_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging'

        def initialize(app, http, notification, batch)
          @app = app
          @http = http
          @notification = notification
          @batch = batch
          @json_private_key = Base64.strict_decode64(app.fcm_json_token)
          project_id = JSON.parse(@json_private_key)['project_id']
          @uri = URI.parse("https://fcm.googleapis.com/v1/projects/#{project_id}/messages:send")
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
          log_info("FCM: #{@notification.id} sent to #{@notification.device_token}")
        end

        def bad_request(response)
          error = parse_error(response)
          reflect(:fcm_bad_request, @notification.id, error)
          fail Rpush::DeliveryError.new(400, @notification.id, "FCM: failed to handle the JSON request. (#{error})")
        end

        def unauthorized
          reflect(:fcm_unauthorized, @notification.id, 'FCM: Bearer token could not be validated.')
          fail Rpush::DeliveryError.new(401, @notification.id, 'FCM: Unauthorized, Bearer token could not be validated.')
        end

        def sender_id_mismatch
          fail Rpush::DeliveryError.new(403, @notification.id, 'FCM: The sender ID was mismatched. It seems the device token is wrong.')
        end

        def unregistered(response)
          error = parse_error(response)
          reflect(:fcm_invalid_device_token, @app, error, @notification.device_token)
          fail Rpush::DeliveryError.new(404, @notification.id, "FCM: Client was not registered for your app. (#{error})")
        end

        def too_many_requests
          fail Rpush::DeliveryError.new(429, @notification.id, 'FCM: Slow down. Too many requests were sent!')
        end

        def internal_server_error(response)
          retry_delivery(@notification, response)
          log_warn("FCM: responded with an Internal Error. " + retry_message)
        end

        def bad_gateway(response)
          retry_delivery(@notification, response)
          log_warn("FCM: responded with a Bad Gateway Error. " + retry_message)
        end

        def service_unavailable(response)
          retry_delivery(@notification, response)
          log_warn("FCM: responded with an Service Unavailable Error. " + retry_message)
        end

        def other_5xx_error(response)
          retry_delivery(@notification, response)
          log_warn("FCM: responded with a 5xx Error. " + retry_message)
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

        def obtain_access_token
          if fetch_access_token?
            token = fetch_access_token
            @app.update(fcm_access_token: token, fcm_access_token_expiration: Time.zone.now + TOKEN_VALID_FOR_SEC)
          end
          @app.fcm_access_token
        end

        def fetch_access_token?
          @app.fcm_access_token.nil? || @app.fcm_access_token_expiration.nil? || @app.fcm_access_token_expiration < Time.zone.now
        end

        def fetch_access_token
          credentials = Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: StringIO.new(@json_private_key),
            scope: AUTH_SCOPE
          )

          token_response = credentials.fetch_access_token!
          token_response['access_token']
        end

        def do_post
          token = obtain_access_token
          post = Net::HTTP::Post.new(@uri.path, 'Content-Type'  => 'application/json',
                                     'Authorization' => "Bearer #{token}")
          post.body = @notification.as_json.to_json
          @http.request(@uri, post)
        end
      end
    end
  end
end
