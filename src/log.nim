import std/logging

var logger = newConsoleLogger(fmtStr="dive: $levelname: ", useStderr=true)
addHandler logger

export debug, error, fatal, info, log, notice, warn, logging
