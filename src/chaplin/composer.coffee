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

  # Temporary stores promises for failed compositions to reject compositions
  # dependent from them
  rejectedCompositionPromises: null

  # Indicated async compose level: 0 - no compose now, 1 - do compose,
  # >1 - new compose started before previous is finished
  composeLevel: 0,

  # Global error handler is called when any composition compose is failed.
  # It gets failed composition item as parameter and continue execution if
  # returns new promise; otherwise composition is removed
  composeError: null

  # Factory method returning a new instance of a deferred class
  deferredCreator: null

  # Deferred object which stores state of current controller action execution
  actionDeferred: null

  constructor: ->
    @initialize arguments...

  initialize: (options = {}) ->
    # Taking a global compose error handler from options
    @composeError = options.composeError

    # Taking a deferred object factory function from options
    @deferredCreator = options.deferredCreator

    # Initialize collections.
    @compositions = {}
    @rejectedCompositionPromises = {}

    # Subscribe to events.
    mediator.setHandler 'composer:compose', @compose, this
    @subscribeEvent 'dispatcher:dispatch', @afterAction

  # Constructs a composition and composes into the active compositions.
  # This function has several forms as described below:
  #
  # 1. compose('name', Class[, options][, dependencies])
  #    Composes a class object. The options are passed to the class when
  #    an instance is contructed and are further used to test if the
  #    composition should be re-composed. Dependencies are used to define
  #    compositions required by this one and provide access to them.
  #    Compositions are resolved from specified names and are passed
  #    to compose and update methods.
  #
  # 2. compose('name', options, function[, dependencies])
  #    Composes a function that executes in the context of the controller;
  #    do NOT bind the function context and is passed the options as a
  #    parameter. The options are further used to test if the composition
  #    should be recomposed. Dependencies are used to define compositions
  #    required by this one and provide access to them.
  #
  # 3. compose('name', options)
  #    Gives control over the composition process; the compose method of
  #    the options hash is executed in place of the function of form (3),
  #    the update method is executed both for new and existing composition,
  #    the check method is called (if present) to determine re-composition (
  #    otherwise this is the same as form [3]) and dependencies array is used
  #    to define composition dependencies.
  #
  # 4. compose('name', CompositionClass[, options][, dependencies])
  #    Gives complete control over the composition process.
  #
  compose: (name, second, third, fourth) ->
    # Normalize the arguments
    # If the second parameter is a function:
    # This is form (1) with the optional options hash if the third
    # is specified or (4) if the second parameter's prototype has a dispose method
    if typeof second is 'function' and second::dispose
      # Handle the case when options are missing, but dependencies are specified
      if utils.isArray third
        fourth = third
        third = {}

      # If the class is a Composition class then it is form (4).
      if second.prototype instanceof Composition
        return @_compose name, composition: second, options: third, dependencies: fourth
      # Else form (1)
      else
        return @_compose name, options: third, dependencies: fourth, compose: ->
          # The compose method here just constructs the class.
          # Model and Collection both take `options` as the second argument.
          if second.prototype instanceof Backbone.Model or second.prototype instanceof Backbone.Collection
            @item = new second null, @options
          else
            @item = new second @options

          # Render this item if it has a render method and it either
          # doesn't have an autoRender property or that autoRender
          # property is false
          autoRender = @item.autoRender
          disabledAutoRender = autoRender is undefined or not autoRender
          if disabledAutoRender and typeof @item.render is 'function'
            @item.render()

    # If the third parameter exists and is a function this is (2).
    if typeof third is 'function'
      return @_compose name, compose: third, options: second, dependencies: fourth

    # This must be form (4).
    return @_compose name, second

  _compose: (name, options) ->
    # Create composition object from specified options
    composition = @_createComposition options

    # Initialize promise object for async operation execution
    promise = @_createPromise()

    # Check for an existing composition
    current = @compositions[name]
    if current
      # Apply the check method
      if current.check composition.options
        # Update current composition with new one
        promise = @_mergeComposition current, composition, promise

        # Reuse current composition
        composition = current
      else
        # Remove the current composition
        current.dispose()

    # Mark the current composition as not stale
    composition.stale false

    # Resolve composition dependencies
    promise = @_resolveDependencies composition, promise

    # Apply compose method for new composition only
    promise = @_composeComposition composition, promise if composition isnt current

    # Apply update method both for new and existing composition
    promise = @_updateComposition composition, promise

    # Add error handling for composition
    promise = @_errorComposition name, composition, promise

    # Prepare final promise resolving to composition item
    promise = @_completeComposition composition, promise

    # Store promise in composition when it needs async operation to complete
    composition.promise = promise

    # Store composition
    @compositions[name] = composition

    # Return composition item or promise which will be resolved to it
    composition.promise

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

      composition.dependencies = options.dependencies if options.dependencies

      composition.check = options.check if options.check

      composition.compose = options.compose

      composition.update = options.update if options.update

      composition.error = options.error if options.error

      composition.afterDispose = options.afterDispose if options.afterDispose

    # Return new composition
    composition

  _createPromise: ->
    if not @deferredCreator?
      throw new Error 'Deferred object factory function is not set'

    # Create action deferred object to track 'dispatcher:dispatch' action and
    # execute new compositions after cleanup of old compositions
    @actionDeferred = @deferredCreator() if not @actionDeferred

    # Return new promise
    @actionDeferred.promise()

  _mergeComposition: (current, composition, promise) ->
    # Take update method from new composition to use latest function context
    current.update = composition.update

    # If current composition is not resolved yet, include its promise to chain
    if current.promise
      _promise = promise
      promise = current.promise.then ->
        _promise
      , ->
        _promise
      delete current.promise

    # Return promise for chain
    promise

  _resolveDependencies: (composition, promise) ->
    # Storage for composition items which are declared as dependencies
    resolvedDependencies = []

    # Enumerate declared composition dependencies
    for dependencyName in composition.dependencies
      # Get composition dependency
      dependency = @compositions[dependencyName]

      # Assert for programmer errors
      if not dependency? or dependency.stale()
        throw new Error "Composition dependency '" + dependencyName + "' is not available"

      # Update promise chain
      promise = do (promise, dependency, dependencyName) =>
        # Chain dependency resolving
        promise.then =>
          # Return rejected promise if dependency was failed
          return @rejectedCompositionPromises[dependencyName] if dependencyName of @rejectedCompositionPromises

          # Return composition item or its promise
          dependency.promise or dependency.item
        .then (item) ->
          # Append composition item (may be empty) to array of dependencies
          resolvedDependencies.push item

    # Return promise for chain
    promise.then ->
      # Resolve to array of dependent composition items
      resolvedDependencies

  _composeComposition: (composition, promise) ->
    # Temporary storage for composition dependencies
    dependencies = null

    # Return promise for chain
    promise.then (resolvedDependencies) ->
      # Store dependencies to pass them further
      dependencies = resolvedDependencies

      # Apply compose method to composition item passing as arguments
      # options and dependent composition items
      composition.compose.apply composition.item, [composition.options].concat resolvedDependencies
    .then ->
      # Resolve to array of dependent composition items
      dependencies

  _updateComposition: (composition, promise) ->
    # Return promise for chain
    promise.then (resolvedDependencies) ->
      # Apply update method to composition item passing as arguments
      # options and dependent composition items
      composition.update.apply composition.item, [composition.options].concat resolvedDependencies

  _errorComposition: (name, composition, promise) ->
    disposeComposition = () =>
      # Save rejected composition promise
      rejectedCompositionPromise = @rejectedCompositionPromises[name] = composition.promise;
      # Dispose composition
      @_disposeComposition name, {}
      # Return rejected composition promise
      rejectedCompositionPromise

    # Return promise for chain
    promise.then (result) ->
      # Bypass result for success
      return result
    , =>
      # Otherwise apply error method to composition item
      errorResult = composition.error.call composition.item, composition.options
      # Apply global error handler if necessary
      errorResult = @composeError composition.item if not errorResult? and @composeError
      # If any handler returned promise
      if errorResult? and errorResult.then
        # Use it to continue execution
        return errorResult.then (result) ->
          # Bypass result for success
          return result
          # Otherwise dispose failed composition
        , disposeComposition
      else
        # Otherwise dispose failed composition
        disposeComposition()

  _completeComposition: (composition, promise) ->
    # Create last promise for compose execution chain
    promise.then ->
      # TODO: Remove promise reference from composition only if it was not renewed
      delete composition.promise if composition.promise is promise

      # Resolve to composition item
      composition.item

  _buildDependentMap: ->
    # Build map of composition dependencies in up-down direction,
    # i.e. compositions which depend from specified
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

    return if not composition

    # Dispose compositions which depends from current first
    dependentNames = dependentMap[name]
    if dependentNames
      for dependentName in dependentNames
        @_disposeComposition dependentName, dependentMap, filter

      # Remove dependency reference to get rid of repeated dispose
      delete dependentMap[name]

    # Check if composition satisfies filter condition
    return if filter and not filter composition

    # Dispose composition
    composition.dispose()

    # Execute after dispose callback
    composition.afterDispose.apply null

    delete @compositions[name]
    return

  _waitForCompose: () ->
    # Initialize promise to accumulate composition promises in
    actionPromise = @deferredCreator().resolve().promise()

    # TODO: Use Promise.all instead of sequence
    # Collect all not resolved composition promises
    for name, composition of @compositions
      # Joins not resolved promises to the chain
      actionPromise = do (actionPromise, composition) ->
        promise = composition.promise

        # Skip resolved compositions
        return actionPromise unless promise

        # Add promise to chain
        actionPromise.then ->
          promise
        , ->
          promise

    actionPromise.then ->
      true
    , ->
      false

  afterAction: ->
    actionDeferred = @actionDeferred

    # Increase compose level before async compose
    @composeLevel++

    # Action method is done; perform post-action clean up
    @cleanup()

    # Resolve action deferred object (if presents)
    # to trigger async composition execution
    if actionDeferred?
      @actionDeferred = null
      actionDeferred.resolve()

    # Wait for all async compositions
    @_waitForCompose().then (success) =>
      # Cleanup temporary stored rejected promises
      @rejectedCompositionPromises = {}
      # Decrease compose level after async compose
      @composeLevel--
      # Dispatch event when all compositions are ready
      @publishEvent 'composer:complete', success if @composeLevel == 0

  # Declare all compositions as stale and remove all that were previously
  # marked stale without being re-composed.
  cleanup: ->
    # Build map of dependencies to dispose compositions in correct order
    dependentMap = @_buildDependentMap()

    # Create stale composition filter function
    staleFilter = (composition) ->
      composition.stale()

    # Dispose and delete all no-longer-active compositions.
    for name of @compositions
      this._disposeComposition name, dependentMap, staleFilter

    # Declare all active compositions as de-activated (eg. to be removed
    # on the next controller startup unless they are re-composed).
    for name, composition of @compositions
      composition.stale true

    # Return nothing.
    return

  dispose: ->
    return if @disposed

    # Unbind handlers of global events
    @unsubscribeAllEvents()

    mediator.removeHandlers this

    # Build map of dependencies to dispose compositions in correct order
    dependentMap = @_buildDependentMap()

    # Dispose of all compositions and their items (that can be)
    @_disposeComposition name, dependentMap for name of @compositions

    # Remove properties
    delete @compositions

    # Finished
    @disposed = true

    # You’re frozen when your heart’s not open
    Object.freeze? this
