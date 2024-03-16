# Package

version       = "0.1.0"
author        = "fox0430"
description   = "SMTP client implementation using chronos"
license       = "MIT"
srcDir        = "src"
bin           = @["smtp"]


# Dependencies

requires "nim >= 1.6.16",
         "chronos >= 4.0.0"
