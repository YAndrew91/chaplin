'use strict'

_ = require 'underscore'
Backbone = require 'backbone'
mediator = require 'chaplin/mediator'
utils = require 'chaplin/lib/utils'
Composition = require 'chaplin/lib/composition'
EventBroker = require 'chaplin/lib/event_broker'

# Composer
# --------

# The sole job of the composer is to allow views to be 'composed'.
#
# If the view has already been composed by a previous action then nothing
# apart from registering the view as in use happens. Else, the view
# is instantiated and passed the options that were passed in. If an action
# is routed to where a view that was composed is not re-composed, the
# composed view is disposed.

module.exports = class Composer
  # Borrow the static extend method from Backbone
  @extend = Backbone.Model.extend

  # Mixin an EventBroker
  _.extend @prototype, EventBroker

  # The collection of composed compositions
  compositions: null

  # Factory method returning a new instance of a deferred class
  deferredCreator: null

  # Deferred object which stores state of current controller action execution
  actionDeferred: null

  constructor: ->
    @initialize arguments...

  initialize: (options = {}) ->
    # Taking a deferred object factory function from options
    @deferredCreator = options.deferredCreator

    # Initialize collections.
    @compositions = {}

    # Subscribe to events.
    mediator.setHandler 'composer:compose', @compose, this
    mediator.setHandler 'composer:retrieve', @retrieve, this
    @subscribeEvent 'dispatcher:dispatch', @afterAction

  # Constructs a composition and composes into the active compositions.
  # This function has several forms as described below:
  #
  # 1. compose('name', Class[, options])
  #    Composes a class object. The options are passed to the class when
  #    an instance is contructed and are further used to test if the
  #    composition should be re-composed.
  #
  # 2. compose('name', function)
  #    Composes a function that executes in the context of the controller;
  #    do NOT bind the function context.
  #
  # 3. compose('name', options, function)
  #    Composes a function that executes in the context of the controller;
  #    do NOT bind the function context and is passed the options as a
  #    parameter. The options are further used to test if the composition
  #    should be recomposed.
  #
  # 4. compose('name', options)
  #    Gives control over the composition process; the compose method of
  #    the options hash is executed in place of the function of form (3) and
  #    the check method is called (if present) to determine re-composition (
  #    otherwise this is the same as form [3]).
  #
  # 5. compose('name', CompositionClass[, options])
  #    Gives complete control over the composition process.
  #
  compose: (name, second, third, fourth) ->
    # Normalize the arguments
    # If the second parameter is a function we know it is (1) or (2).
    if typeof second is 'function'
      # This is form (1) or (5) with the optional options hash if the third
      # is an obj or the second parameter's prototype has a dispose method
      if third or second::dispose
        #
        if _.isArray third
          fourth = third
          third = {}

        # If the class is a Composition class then it is form (5).
        if second.prototype instanceof Composition
          return @_compose name, composition: second, options: third, dependencies: fourth
        else
          return @_compose name, options: third, dependencies: fourth, compose: ->
            # The compose method here just constructs the class.
            @item = new second @options

            # Render this item if it has a render method and it either
            # doesn't have an autoRender property or that autoRender
            # property is false
            autoRender = @item.autoRender
            disabledAutoRender = autoRender is undefined or not autoRender
            if disabledAutoRender and typeof @item.render is 'function'
              @item.render()

      # This is form (2).
      return @_compose name, compose: second

    # If the third parameter exists and is a function this is (3).
    if typeof third is 'function'
      return @_compose name, compose: third, options: second, dependencies: fourth

    # This must be form (4).
    return @_compose name, second

  _compose: (name, options) ->
    #
    composition = @_createComposition options

    #
    promise = @_createPromise()

    # Check for an existing composition
    current = @compositions[name]

    if current
      #
      if current.check composition.options
        #
        current.update = composition.update

        #
        composition = current

        #
        if current.promise
          promise = current.promise.then -> promise
          delete current.promise
      else
        #
        current.dispose()

    #
    composition.stale false

    #
    promise = @_resolveDependencies composition, promise

    #
    promise = @_composeComposition composition, promise if composition isnt current

    #
    promise = @_updateComposition composition, promise

    #
    composition.promise = promise if promise

    #
    @compositions[name] = composition

    #
    composition.promise or composition.item

  _createComposition: (options) ->
    # Assert for programmer errors
    if typeof options.compose isnt 'function' and not options.composition?
      throw new Error 'Composer#compose was used incorrectly'

    if options.composition?
      # Use the passed composition directly
      composition = new options.composition options.options
    else
      # Create the composition and apply the methods (if available)
      composition = new Composition options.options

      #
      composition.dependencies = options.dependencies if options.dependencies

      composition.check = options.check if options.check

      composition.compose = options.compose

      composition.update = options.update if options.update

    composition

  _createPromise: ->
    # Create
    @actionDeferred = @deferredCreator() if not @actionDeferred and @deferredCreator

    if @actionDeferred
      #
      promise = @actionDeferred.promise()
    else
      #
      promise = then: (done) ->
        #
        result = done @result

        #
        return result if result and result.then

        #
        @result = result

        this

    promise

  _resolveDependencies: (composition, promise) ->
    #
    resolvedDependencies = []

    #
    _.each composition.dependencies, (dependencyKey) =>
      promise = promise.then =>
        #
        dependency = @compositions[dependencyKey]

        #
        return undefined if not dependency? or (not @deferredCreator? and dependency.stale())

        dependency.promise or dependency.item
      .then (item) ->
        #
        resolvedDependencies.push item

    promise.then ->
      resolvedDependencies

  _composeComposition: (composition, promise) ->
    dependencies = null
    promise.then (resolvedDependencies) ->
      dependencies = resolvedDependencies
      composition.compose.apply composition.item, [composition.options].concat resolvedDependencies
    .then ->
      dependencies

  _updateComposition: (composition, promise) ->
    resolved = null

    promise = promise.then (resolvedDependencies) ->
      composition.update.apply composition.item, [composition.options].concat resolvedDependencies
    .then ->
      resolved = true

      #
      return if composition.disposed

      #
      delete composition.promise if composition.promise is promise

      composition.item

    #
    if resolved then null else promise

  # Retrieves an active composition using the compose method.
  retrieve: (name) ->
    active = @compositions[name]
    (if active and not active.stale() then active.promise or active.item else undefined)

  _buildDependentMap: ->
    result = {}

    for name, composition of @compositions
      dependencies = composition.dependencies
      if dependencies
        for dependencyName in dependencies
          dependentNames = result[dependencyName]
          result[dependencyName] = dependentNames = [] if not dependentNames
          dependentNames.push name

    result

  _disposeComposition: (name, dependentMap, filter) ->
    composition = @compositions[name]
    dependentNames = dependentMap[name]

    return if not composition

    if dependentNames
      for dependentName in dependentNames
        @_disposeComposition dependentName, dependentMap, filter

      delete dependentMap[name]

    return if filter and not filter composition

    composition.dispose()

    delete @compositions[name]

  afterAction: ->
    actionDeferred = @actionDeferred

    @cleanup()

    if actionDeferred?
      @actionDeferred = null
      actionDeferred.resolve()

  # Declare all compositions as stale and remove all that were previously
  # marked stale without being re-composed.
  cleanup: ->
    #
    dependentMap = @_buildDependentMap()

    #
    staleFilter = (composition) ->
      composition.stale()

    #
    # Action method is done; perform post-action clean up
    # Dispose and delete all no-longer-active compositions.
    # Declare all active compositions as de-activated (eg. to be removed
    # on the next controller startup unless they are re-composed).
    for name of @compositions
      this._disposeComposition name, dependentMap, staleFilter

    for name, composition of @compositions
      composition.stale true

    # Return nothing.
    return

  dispose: ->
    return if @disposed

    # Unbind handlers of global events
    @unsubscribeAllEvents()

    mediator.removeHandlers this

    #
    dependentMap = @_buildDependentMap()

    # Dispose of all compositions and their items (that can be)
    @_disposeComposition name, dependentMap for name of @compositions

    # Remove properties
    delete @compositions

    # Finished
    @disposed = true

    # You’re frozen when your heart’s not open
    Object.freeze? this
