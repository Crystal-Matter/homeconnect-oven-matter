module HomeconnectOven
  VERSION = "0.1.0"
end

require "matter"
require "homeconnect_local"
require "goban"
require "option_parser"
require "log"
require "file_utils"

require "./homeconnect-oven/controller"
require "./homeconnect-oven/matter"
require "./homeconnect-oven/cli"
# require "./homeconnect-oven/mdns_patch"
