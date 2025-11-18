# Package

version       = "0.7.0"
author        = "fox0430"
description   = "SMTP client implementation using chronos"
license       = "MIT"
bin           = @["chronos_smtp"]


# Dependencies

requires "nim >= 2.0.16",
         "chronos >= 4.0.0",
         "chronicles >= 0.10.3"
