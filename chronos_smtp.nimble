# Package

version       = "0.3.0"
author        = "fox0430"
description   = "SMTP client implementation using chronos"
license       = "MIT"
bin           = @["chronos_smtp"]


# Dependencies

requires "nim >= 1.6.16",
         "chronos >= 4.0.0"
