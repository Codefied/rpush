module Rpush
  module Client
    module ActiveModel
      module Fcm
        module Notification
          FCM_PRIORITY_HIGH = Rpush::Client::ActiveModel::Apns::Notification::APNS_PRIORITY_IMMEDIATE
          FCM_PRIORITY_NORMAL = Rpush::Client::ActiveModel::Apns::Notification::APNS_PRIORITY_CONSERVE_POWER
          FCM_PRIORITIES = [FCM_PRIORITY_HIGH, FCM_PRIORITY_NORMAL]

          ROOT_NOTIFICATION_KEYS = %w[title body image].freeze
          ANDROID_NOTIFICATION_KEYS = %w[icon tag color click_action body_loc_key body_loc_args title_loc_key
                                         title_loc_args channel_id ticker sticky event_time local_only
                                         default_vibrate_timings default_light_settings vibrate_timings
                                         visibility notification_count light_settings sound].freeze

          def self.included(base)
            base.instance_eval do
              validates :device_token, presence: true
              validates :priority, inclusion: { in: FCM_PRIORITIES }, allow_nil: true

              validates_with Rpush::Client::ActiveModel::PayloadDataSizeValidator, limit: 4096

              validates_with Rpush::Client::ActiveModel::Fcm::ExpiryCollapseKeyMutualInclusionValidator
              validates_with Rpush::Client::ActiveModel::Fcm::NotificationKeysInAllowedListValidator
            end
          end

          def payload_data_size
            multi_json_dump(as_json['message']['data']).bytesize
          end

          # This is a hack. The schema defines `priority` to be an integer, but FCM expects a string.
          # But for users of rpush to have an API they might expect (setting priority to `high`, not 10)
          # we do a little conversion here.
          def priority=(priority)
            case priority
            when 'high', FCM_PRIORITY_HIGH
              super(FCM_PRIORITY_HIGH)
            when 'normal', FCM_PRIORITY_NORMAL
              super(FCM_PRIORITY_NORMAL)
            else
              errors.add(:priority, 'must be one of either "normal" or "high"')
            end
          end

          def dry_run=(value)
            fail ArgumentError, 'FCM does not support dry run' if value
          end

          def mutable_content=(value)
            fail ArgumentError, 'RPush does not currently support mutable_content for FCM' if value
          end

          def as_json(options = nil)
            json = {
              'data' => data,
              'android' => android_config,
              'token' => device_token
            }
            json['notification'] = root_notification if notification
            { 'message' => json }
          end

          def android_config
            {
              'collapse_key' => (collapse_key if collapse_key),
              'priority' => (priority_str if priority),
              'ttl' => ("#{expiry}s" if expiry)
            }
          end

          def notification=(value)
            super(value.with_indifferent_access)
          end

          def root_notification
            return {} unless notification

            notification.slice(*ROOT_NOTIFICATION_KEYS)
          end

          def priority_str
            case
            when priority <= 5 then 'normal'
            else
              'high'
            end
          end
        end
      end
    end
  end
end
