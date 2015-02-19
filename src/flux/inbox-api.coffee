_ = require 'underscore-plus'
request = require 'request'
Actions = require './actions'
{APIError} = require './errors'
DatabaseStore = require './stores/database-store'
NamespaceStore = require './stores/namespace-store'
InboxLongConnection = require './inbox-long-connection'
{modelFromJSON, modelClassMap} = require './models/utils'
async = require 'async'

class InboxAPI

  constructor: ->
    @_streamingConnections = []
    atom.config.onDidChange('inbox.env', @_onConfigChanged)
    atom.config.onDidChange('inbox.token', @_onConfigChanged)
    @_onConfigChanged()

    NamespaceStore.listen(@_onNamespacesChanged, @)
    @_onNamespacesChanged()
    @

  _onConfigChanged: =>
    prev = {@APIToken, @AppID, @APIRoot}

    @APIToken = atom.config.get('inbox.token')
    env = atom.config.get('inbox.env')
    if env in ['production']
      @AppID = 'c96gge1jo29pl2rebcb7utsbp'
      @APIRoot = 'https://api.nilas.com'
    else if env in ['staging', 'development']
      @AppID = '54miogmnotxuo5st254trcmb9'
      @APIRoot = 'https://api-staging.nilas.com'

    current = {@APIToken, @AppID, @APIRoot}

    if atom.state.mode is 'editor'
      if not @APIToken?
        @_closeStreamingConnections()

      if not _.isEqual(prev, current)
        @makeRequest
          path: "/n"
          returnsModel: true

      console.log(@_streamingConnections.length)

  _onNamespacesChanged: ->
    return unless atom.state.mode is 'editor'
    return if atom.getLoadSettings().isSpec
    
    namespaces = NamespaceStore.items()
    connections = _.map(namespaces, @_streamingConnectionForNamespace)

    # Close the connections that are not in the new connections list.
    # These namespaces are no longer in our database, so we shouldn't
    # be listening.
    old = _.without(@_streamingConnections, connections...)
    conn.end() for conn in old

    @_streamingConnections = connections

  _closeStreamingConnections: ->
    for conn in @_streamingConnections
      conn.end()
    @_streamingConnections = []

  _streamingConnectionForNamespace: (namespace) =>
    connection = _.find @_streamingConnections, (c) ->
      c.namespaceId() is namespace.id
    console.log('Found existing connection') if connection
    return connection if connection

    connection = new InboxLongConnection(@, namespace.id)

    if !connection.hasCursor()
      @getThreads(namespace.id)
      @getCalendars(namespace.id)

    connection.onStateChange (state) ->
      Actions.longPollStateChanged(state)
      if state == InboxLongConnection.State.Connected
        Actions.restartTaskQueue()

    connection.onDeltas (deltas) =>
      @_handleDeltas(namespace.id, deltas)
      Actions.restartTaskQueue()

    connection.start()
    connection

  # Delegates to node's request object.
  # On success, it will call the passed in success callback with options.
  # On error it will create a new APIError object that wraps the error,
  # response, and body.
  #
  # Options:
  #   {Any option that node's request takes}
  #   returnsModel - boolean to determine if the response should be
  #                  unpacked into an Inbox data wrapper
  #   success: (body) -> callback gets passed the returned json object
  #   error: (apiError) -> the error callback gets passed an Inbox
  #                        APIError object.
  makeRequest: (options={}) ->
    return if atom.getLoadSettings().isSpec
    return console.log('Cannot make Inbox request without auth token.') unless @APIToken
    options.method ?= 'GET'
    options.url ?= "#{@APIRoot}#{options.path}" if options.path
    options.body ?= {} unless options.formData
    options.json ?= true
    options.auth = {'user': @APIToken, 'pass': '', sendImmediately: true}
    options.error ?= @_defaultErrorCallback

    request options, (error, response, body) =>
      Actions.didMakeAPIRequest({request: options, response: response})
      if error? or response.statusCode > 299
        options.error(new APIError({error:error, response:response, body:body}))
      else
        if _.isString body
          try
            body = JSON.parse(body)
          catch error
            options.error(new APIError({error:error, response:response, body:body}))
        @_handleModelResponse(body) if options.returnsModel
        options.success(body) if options.success

  _handleDeltas: (namespaceId, deltas) ->
    console.log("Processing deltas:")

    # Group deltas by object type so we can mutate our local cache efficiently
    deltasByObject = {}
    deltasDeletions = []
    for delta in deltas
      if delta.event is 'delete'
        deltasDeletions.push(delta)
      else if delta.event is 'create' or delta.event is 'modify'
        deltasByObject[delta.object] ||= []
        deltasByObject[delta.object].push(delta.attributes)

    # Remove events and contacts - we don't apply deltas to them
    delete deltasByObject['contact']
    delete deltasByObject['event']

    # Apply all the create / modfiy events by class
    for object, items of deltasByObject
      console.log(" + #{items.length} #{object}")
      @_handleModelResponse(items)

    # Apply all of the deletions
    for delta in deltasDeletions
      console.log(" - 1 #{delta.object} (#{delta.id})")
      klass = modelClassMap()[delta.object]
      return unless klass
      DatabaseStore.find(klass, delta.id).then (model) ->
        DatabaseStore.unpersistModel(model) if model

  _defaultErrorCallback: (apiError) ->
    console.error("Unhandled Inbox API Error:", apiError.message, apiError)

  _handleModelResponse: (json) ->
    throw new Error("handleModelResponse with no JSON provided") unless json
    json = [json] unless json instanceof Array

    async.filter json
    , (json, callback) =>
      @_shouldAcceptModel(json.object, json).then((-> callback(true)), (-> callback(false)))
    , (json) ->
      # Save changes to the database, which will generate actions
      # that our views are observing.
      objects = []
      for objectJSON in json
        objects.push(modelFromJSON(objectJSON))
      DatabaseStore.persistModels(objects) if objects.length > 0

  _shouldAcceptModel: (classname, model = null) ->
    return Promise.resolve() unless model

    if classname is "thread"
      Thread = require './models/thread'
      return @_shouldAcceptModelIfNewer(Thread, model)

    # For some reason, we occasionally get a delta with:
    # delta.object = 'message', delta.attributes.object = 'draft'
    if classname is "draft" or model?.object is "draft"
      Message = require './models/message'
      return @_shouldAcceptModelIfNewer(Message, model)

    Promise.resolve()

  _shouldAcceptModelIfNewer: (klass, model = null) ->
    new Promise (resolve, reject) ->
      DatabaseStore = require './stores/database-store'
      DatabaseStore.find(klass, model.id).then (existing) ->
        if existing and existing.version >= model.version
          reject(new Error("Rejecting version #{model.version}. Local version is #{existing.version}."))
        else
          resolve()

  getThreadsForSearch: (namespaceId, query, callback) ->
    throw (new Error "getThreadsForSearch requires namespaceId") unless namespaceId
    @makeRequest
      method: 'POST'
      path: "/n/#{namespaceId}/threads/search"
      body: {"query": query}
      json: true
      returnsModel: false
      success: (json) ->
        objects = []
        for resultJSON in json.results
          obj = modelFromJSON(resultJSON.object)
          obj.relevance = resultJSON.relevance
          objects.push(obj)

        DatabaseStore.persistModels(objects) if objects.length > 0
        callback(objects)

  # TODO remove from inbox-api and put in individual stores. The general
  # API abstraction should not need to know about threads and calendars.
  # They're still here because of their dependency in
  # _postLaunchStartStreaming
  getThreads: (namespaceId, params) ->
    @getCollection(namespaceId, 'threads', params)

  getCalendars: (namespaceId) ->
    @getCollection(namespaceId, 'calendars', {})

  getCollection: (namespaceId, collection, params={}) ->
    throw (new Error "getCollection requires namespaceId") unless namespaceId
    @makeRequest
      path: "/n/#{namespaceId}/#{collection}"
      qs: params
      returnsModel: true

module.exports = InboxAPI