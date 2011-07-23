pathParser = require './pathParser'

PubSub = module.exports = (adapterName = 'Redis', options) ->
  @_adapter = new PubSub._adapters[adapterName] this, options
  return

PubSub:: =
  # subscribe(subscriberId, paths..., callback)
  subscribe: ->
    @_adapter.subscribe arguments...

  publish: (publisherId, path, message) ->
    @_adapter.publish arguments...
  
  # unsubscribe(subscriberId, paths..., callback)
  unsubscribe: ->
    @_adapter.unsubscribe arguments...
  flush: (callback) ->
    @_adapter.flush callback
  disconnect: (callback) ->
    @_adapter.disconnect callback

PubSub._adapters = {}
redis = require 'redis'
# redis.debug_mode = true
PubSub._adapters.Redis = RedisAdapter = (pubsub, options = {}) ->
  @pubsub = pubsub

  @_pathsBySubscriber = {}
  @_subscribersByPath = {}
  @_patternsBySubscriber = {}
  @_subscribersByPattern = {}

  @_publishClient = options.client || redis.createClient()
  @_subscribeClient = redis.createClient()

  @_subscribeClient.on 'subscribe', (path, count) =>
    if pubsub.debug
      console.log "SUBSCRIBING #{path} - COUNT = #{count}"
    return
  @_subscribeClient.on 'message', (path, message) =>
    # TODO Invert this for performance? i.e., function calls
    # are expensive, so place for loop in the onMessage function
    # and do the same for `@_subscribeClient.on 'pmessage'...`
    throw new Error 'You must define pubsub.onMessage' unless onMessage = pubsub.onMessage
    subscribers = @_subscribersByPath[path]
    if subscribers
      for subscriberId in subscribers
        onMessage subscriberId, JSON.parse message
  @_subscribeClient.on 'unsubscribe', (path, count) =>
    if pubsub.debug
      console.log "UNSUBSCRIBING #{path} - COUNT = #{count}"
    return

  @_subscribeClient.on 'psubscribe', (pattern, count) ->
    if pubsub.debug
      console.log "PSUBSCRIBING #{pattern} - COUNT = #{count}"
    return
  @_subscribeClient.on 'pmessage', (pattern, channel, message) =>
    throw new Error 'You must define pubsub.onMessage' unless onMessage = pubsub.onMessage
    message = JSON.parse message
    subscribers = @_subscribersByPattern[pattern]
    if subscribers
      for subscriberId in subscribers
        onMessage subscriberId, message
    subscribers = @_subscribersByPath[channel]
    if subscribers
      for subscriberId in subscribers
        pubsub.onMessage subscriberId, message
  @_subscribeClient.on 'punsubscribe', (pattern, count) ->
    if pubsub.debug
      console.log "PUNSUBSCRIBING #{pattern} - COUNT = #{count}"
    return

  return

RedisAdapter:: =
  _index: (subscriberId, path, pathType) ->
    paths = @['_' + pathType.toLowerCase() + 'sBySubscriber'][subscriberId] ||= []
    paths.push path

    subscribers = @['_subscribersBy' + pathType][path] ||= []
    subscribers.push subscriberId

  _unindex: (subscriberId, path, pathType) ->
    if (path)
      paths = @['_' + pathType.toLowerCase() + 'sBySubscriber'][subscriberId]
      return unless paths
      paths.splice(paths.indexOf(path), 1)

      subscribers = @['_subscribersBy' + pathType][path]
      subscribers.splice(subscribers.indexOf(subscriberId), 1)
      delete @['_subscribersBy' + pathType][path] unless subscribers.length
    else
      # More efficient way to remove *all* traces of a subscriber
      # than evaling above if multiple times
      for pathType in ['Pattern', 'Path']
        paths = @['_' + pathType.toLowerCase() + 'sBySubscriber'][subscriberId]
        delete @['_' + pathType.toLowerCase() + 'sBySubscriber'][subscriberId]
        for path in paths
          subscribers = @['_subscribersBy' + pathType][path]
          subscribers.splice(subscribers.indexOf(subscriberId), 1)
          delete @['_subscribersBy' + pathType][path] unless subscribers.length

  _lacksSubscribers: (path) ->
    !(@_subscribersByPath[path] || @_subscribersByPattern[path])

  _isIndexed: (path, subscriberId) ->
    pathIndex = @_subscribersByPath[path]?.indexOf subscriberId
    patternIndex = @_subscribersByPattern[path]?.indexOf subscriberId
    pathIndex is not undefined && !!~pathIndex || patternIndex is not undefined && !!~patternIndex

  # subscriberId wants to subscribe to [paths]. This method checks [paths]
  # against the patterns that subscriberId is subscribed to and returns a
  # hash that maps each relevant pattern to the [_paths_] they pattern-match
  # from [paths]. This is used to figure out which paths we should not subscribe
  # to despite subscribe being called on them.
  _alreadySubscribedToViaPatterns: (subscriberId, paths) ->
    patterns = @_patternsBySubscriber[subscriberId]
    @_generatePathPatternCoverageMap patterns, paths

  # subscriberId wants to subscribe to [patterns]. This method checks [patterns]
  # against the paths that subscriberId is subscribed to and returns a
  # hash that maps each relevant pattern to the [_paths_] they pattern-match
  # where [_paths_] is a subset of the paths that subscriberId is currently
  # subscribed to. This is used to figure out which paths we are currently
  # subscribed to that we should unsubscribe to, because we are about to
  # subscribe to a pattern that pattern-matches the currently subscribed path.
  _toBeSubscribedToViaPatterns: (subscriberId, patterns) ->
    paths = @_patternsBySubscriber[subscriberId]
    paths = (paths ? []).concat(@_pathsBySubscriber[subscriberId] ? [])
    @_generatePathPatternCoverageMap patterns, paths

  # Returns a hash that maps pattern -> [paths]. The map is interpreted as:
  # Each path in [paths] does not need to be subscribed to because the pattern
  # that maps to [paths] will pattern match every path in [paths].
  _generatePathPatternCoverageMap: (patterns, paths) ->
    return {} unless patterns && patterns.length && paths && paths.length
    conflictsWithPattern = pathParser.conflictsWithPattern
    patterns.reduce (conflicts, pattern) ->
      conflictPaths = paths.filter (path) ->
        conflictsWithPattern(path, pattern)
      if conflictPaths.length
        conflicts[pattern] = conflictPaths
      conflicts
    , {}

  _handleCoverage: ({coverageMethod, subscriberId, incomingPathsOrPatterns, warningFn, overlapCallback}) ->
    coverageMap = @[coverageMethod] subscriberId, incomingPathsOrPatterns
    if Object.keys(coverageMap).length
      if @pubsub.debug
        console.log warningFn coverageMap
      for pattern, coveredPaths of coverageMap
        overlapCallback pattern, coveredPaths

  subscribe: (subscriberId, paths..., callback) ->
    # return could occur if subscribe called in the context of rally.store
    return if subscriberId is undefined

    if 'function' != typeof callback
      paths.push(callback)
      callback = null

    {paths, patterns, exceptions} = pathParser.forSubscribe paths

    @_handleCoverage
      coverageMethod: '_alreadySubscribedToViaPatterns'
      subscriberId: subscriberId
      incomingPathsOrPatterns: paths
      warningFn: (coverageMap) ->
        warning = "The following patterns already give you subscriptions to the following paths/patterns:\n"
        warning += "#{pattern}: #{coveredPaths.join(', ')}" for pattern, coveredPaths of coverageMap
      overlapCallback: (pattern, coveredPaths) ->
        paths = paths.filter (path) -> (-1 == coveredPaths.indexOf path)

    toSubscribe = paths.filter (path) => @_lacksSubscribers path
    toIndex = toSubscribe.filter (path) => !@_isIndexed path, subscriberId
    if toSubscribe.length
      @_subscribeClient.subscribe toSubscribe...
    @_index subscriberId, path, 'Path' for path in toIndex


    @_handleCoverage
      coverageMethod: '_toBeSubscribedToViaPatterns'
      subscriberId: subscriberId
      incomingPathsOrPatterns: patterns
      warningFn: (coverageMap) ->
        warning = "The following path subscriptions will now be covered by the following patterns:\n"
        warning += "#{pattern}: #{coveredPaths.join(', ')}" for pattern, coveredPaths of coverageMap
      overlapCallback: (pattern, coveredPaths) =>
        @unsubscribe subscriberId, coveredPaths...

    @_handleCoverage
      coverageMethod: '_alreadySubscribedToViaPatterns'
      subscriberId: subscriberId
      incomingPathsOrPatterns: patterns
      warningFn: (coverageMap) ->
        warning = "The following patterns already give you subscriptions to the following paths/patterns:\n"
        warning += "#{pattern}: #{coveredPaths.join(', ')}" for pattern, coveredPaths of coverageMap
      overlapCallback: (pattern, coveredPaths) ->
        patterns = patterns.filter (currPattern) -> (-1 == coveredPaths.indexOf currPattern)

    toSubscribe = patterns.filter (pattern) => @_lacksSubscribers pattern
    toIndex = toSubscribe.filter (path) => !@_isIndexed path, subscriberId
    if toSubscribe.length
      @_subscribeClient.psubscribe toSubscribe...
    @_index subscriberId, path, 'Pattern' for path in toIndex

  publish: (publisherId, path, message) ->
    if @pubsub.debug
      console.log "PUBLISHING the following to #{path}:"
      console.log message
    @_publishClient.publish path, JSON.stringify message

  unsubscribe: (subscriberId, paths..., callback) ->
    return if subscriberId is undefined

    if !paths.length
      if 'string' != typeof callback
        # For signature: unsbuscribe(subscriberId[, callback])
        for pathType in ['path', 'pattern']
          if paths = @['_' + pathType + 'sBySubscriber'][subscriberId]
            @unsubscribe subscriberId, paths..., callback
        return

      # For signature: unsubscribe(subscriberId, path, callback)
      paths.push callback
      callback = null

    # For signature: unsubscribe(subscriberId, paths..., callback)

    {paths, patterns, exceptions} = pathParser.forSubscribe paths

    if paths.length
      @_unindex subscriberId, path, 'Path' for path in paths
      paths = paths.filter @_lacksSubscribers.bind(@)
      @_subscribeClient.unsubscribe paths...
    if patterns.length
      @_unindex subscriberId, path, 'Pattern' for path in patterns
      patterns = patterns.filter @_lacksSubscribers.bind(@)
      @_subscribeClient.punsubscribe pattern for pattern in patterns
      # TODO Replace above line with below line, after patching npm redis
      # @_subscribeClient.punsubscribe patterns...

  flush: (callback) ->
    @_publishClient.flushdb =>
      @_pathsBySubscriber = {}
      @_subscribersByPath = {}
      @_patternsBySubscriber = {}
      @_subscribersByPattern = {}
      callback()

  disconnect: (callback) ->
    @_subscribeClient.end()
    @_publishClient.end()
    callback()
