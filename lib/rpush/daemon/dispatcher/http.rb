module Rpush
  module Daemon
    module Dispatcher
      class Http
        def initialize(app, delivery_class, options = {})
          @app = app
          @delivery_class = delivery_class
          @http = if Gem::Version.new(Net::HTTP::Persistent::VERSION) < Gem::Version.new('3.0.0')
                    Net::HTTP::Persistent.new('rpush')
                  else
                    Net::HTTP::Persistent.new(name: 'rpush')
                  end
        end

        def dispatch(notification, batch)
          @delivery_class.new(@app, @http, notification, batch).perform
        end

        def cleanup
          @http.shutdown
        end
      end
    end
  end
end
