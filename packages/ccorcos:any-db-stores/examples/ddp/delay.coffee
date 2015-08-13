# This is some ass-backwards way to delay within a fiber on the server to simulate latency
if Meteor.isServer
  Future = Npm.require('fibers/future')

  delay = (ms, f) -> Meteor.setTimeout(f, ms)

  delayWithCallback = (ms, func, callback) ->
    delay ms, -> callback(null, func())

  syncify = (f) ->
    (args...) ->
      fut = new Future()
      callback = Meteor.bindEnvironment (error, result) ->
        if error
          fut.throw(error)
        else
          fut.return(result)
      f.apply(this, args.concat(callback))
      return fut.wait()

  @syncDelay = syncify(delayWithCallback)
