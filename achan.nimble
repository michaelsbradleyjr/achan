packageName  = "achan"
version      = "0.1.0"
author       = "Michael Bradley, Jr."
description  = "Asynchronous channels for Nim"
license      = "Apache-2.0 or MIT"
installDirs  = @["achan"]
installFiles = @["LICENSE", "LICENSE-APACHEv2", "LICENSE-MIT", "achan.nim"]

requires "nim >= 2.0.0",
         "asynctest#head",
         "chronos#head",
         "threading#head"
