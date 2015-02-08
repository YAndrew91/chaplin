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

  # Unique ID of current dispatcher state
  currentStateId: null,

  # Global error handler is called when any composition compose is failed.
  # It gets failed composition item as parameter and continue execution if
  # returns new promise; otherwise composition is removed
  composeError: null

  # Promise implementation compatible with ES6 Promise API
  Promise: null

  # Deferred object which stores state of current controller action execution
  actionDeferred: null

  constructor: ->
    @initialize arguments...

  initialize: (options = {}) ->
    # Taking a global compose error handler from options
    @composeError = options.composeError

    # Taking a Promise implementation from options
    @Promise = options.Promise

    # Initialize collections.
    @compositions = {}

    # Subscribe to events.
    mediator.setHandler 'composer:compose', @compose, this
    @subscribeEvent 'dispatcher:initializeState', @beforeAction
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
    newComposition = @_createComposition options

    # Initialize promise object for async operation execution
    promise = @_createPromise(newComposition)

    # Check for an existing composition
    currentComposition = @compositions[name]
    if currentComposition
      # Apply the check method
      if currentComposition.check newComposition.options
        # Update current composition with new one
        promise = @_mergeComposition promise, name, currentComposition

        # Reuse current composition
        composition = currentComposition
      else
        # Use new composition
        composition = newComposition

        # Build map of dependencies to dispose compositions in correct order
        dependentMap = @_buildDependentMap()

        # Remove the current composition
        @_disposeComposition name, dependentMap
    else
      # Use new composition
      composition = newComposition

    # Mark the current composition as not stale
    composition.stale false

    # Also set stale property on the new composition
    # for a case when currentComposition promise fails in @_mergeComposition
    newComposition.stale false if composition isnt newComposition

    # Store composition
    @compositions[name] = composition

    # Resolve composition dependencies
    promise = @_resolveDependencies promise, composition.dependencies

    # Apply compose method for new composition only
    promise = @_composeComposition promise

    # Apply update method both for new and existing composition
    promise = @_updateComposition promise

    # Add error handling for composition
    promise = @_errorComposition promise, name

    # Store promise in composition when it needs async operation to complete
    composition.promise = promise

    # Also set promise property on the new composition
    # for a case when currentComposition promise fails in @_mergeComposition
    newComposition.promise = promise if composition isnt newComposition

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

  _createPromise: (composition) ->
    if not @Promise?
      throw new Error 'Promise implementation is not set'

    # Create action deferred object to track 'dispatcher:dispatch' action and
    # execute new compositions after cleanup of old compositions
    @actionDeferred = utils.Deferred @Promise if not @actionDeferred

    # Return new promise
    @actionDeferred.promise().then ->
      composition

  _mergeComposition: (promise, name, currentComposition) ->
    # Save link to a promise of currentComposition
    # because it promise field be synchronously updated in @_compose
    currentCompositionPromise = currentComposition.promise

    promise.then (newComposition) =>
      # Use the latest update method with the old composition
      currentComposition.update = newComposition.update

      currentCompositionPromise.then (currentComposition) ->
        currentComposition
      , =>
        if currentComposition.composed
          # Restore promise with the old composition
          @Promise.resolve currentComposition
        else
          # Build map of dependencies to dispose compositions in correct order
          dependentMap = @_buildDependentMap()
          # Remove the current composition
          @_disposeComposition name, dependentMap
          # Store the new composition
          @compositions[name] = newComposition
          # Restore promise with the new composition
          @Promise.resolve newComposition

  _resolveDependencies: (promise, dependencies) ->
    # Initialize an array for collecting dependency promises
    dependencyPromises = []

    # Collect composition dependency promises
    for dependencyName in dependencies
      dependency = @compositions[dependencyName]

      # Assert for programmer errors
      if not dependency? or dependency.stale()
        throw new Error "Composition dependency '" + dependencyName + "' is not available"

      dependencyPromises.push dependency.promise

    promise.then (composition) =>
      # Wait for all composition dependencies
      dependenciesPromise = @Promise.all dependencyPromises
      dependenciesPromise.then (dependencyCompositions) ->
        # Forward not dependency compositions but its items
        dependencyItems = _.map dependencyCompositions, (dependencyComposition) -> dependencyComposition.item
        # Add array of dependency composition items to a resolution arguments
        [composition, dependencyItems]

  _composeComposition: (promise) ->
    # Save current dispatcher state to be able to check if it's changed later
    initStateId = @currentStateId

    # Return promise for chain
    promise.then ([composition, dependencyItems]) =>
      # Reject composition promise if dispatcher state changed (redirect case)
      if @currentStateId isnt initStateId
        return @Promise.reject { abort: true }

      # Skip calling compose method if it has been already called (redirect case)
      if composition.composed
        return [composition, dependencyItems]

      # Apply compose method to composition item passing as arguments
      # options and dependent composition items
      composeResult = composition.compose.apply composition.item, [composition.options].concat dependencyItems

      # Guarantee that result of the compose call is a promise
      composePromise = @Promise.resolve composeResult

      composePromise.then ->
        # Mark composition as successfully composed
        composition.composed = true

        # Resolve to the composition and the array of dependency composition items
        [composition, dependencyItems]

  _updateComposition: (promise) ->
    # Save current dispatcher state to be able to check if it's changed later
    initStateId = @currentStateId

    # Return promise for chain
    promise.then ([composition, dependencyItems]) =>
      # Reject composition promise if dispatcher state changed (redirect case)
      if @currentStateId isnt initStateId
        return @Promise.reject { abort: true }

      # Apply update method to composition item passing as arguments
      # options and dependent composition items
      updateResult = composition.update.apply composition.item, [composition.options].concat dependencyItems

      # Guarantee that result of the update call is a promise
      updatePromise = @Promise.resolve updateResult

      updatePromise.then ->
        # Resolve to the composition
        composition

  _errorComposition: (promise, name) ->
    # Return promise for chain
    promise.then (composition) ->
      # Bypass result for success
      return composition
    , (error) =>
      # Bypass action abort
      if error.abort
        return @Promise.reject error

      # Get rejected composition
      composition = @compositions[name]
      # Otherwise apply error method to composition item
      errorResult = composition.error.call composition.item, error, composition.options
      # Apply global error handler if necessary
      errorResult = @composeError error, composition.item if not errorResult? and @composeError
      # If any handler returned promise
      if errorResult? and errorResult.then
        # Use it to continue execution
        @Promise.resolve errorResult
      else
        # Bypass error
        @Promise.reject error

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

    # Execute after dispose callback only if compose is done
    composition.afterDispose.apply null if composition.composed

    delete @compositions[name]
    return

  _waitForCompose: () ->
    # Collect all composition promises
    compositionPromises = []
    for name, composition of @compositions
      compositionPromises.push composition.promise

    # Wait for all compositions
    compositionsPromise = @Promise.all compositionPromises
    compositionsPromise.then ->
      # Resolve promise to true
      true
    , (error) =>
      # Bypass action abort
      if error.abort
        return @Promise.reject error

      # Else restore promise with a value false
      false

  beforeAction: ->
    actionDeferred = @actionDeferred

    # Reject action deferred object (if presents)
    # to prevent from starting async composition execution
    # for previous dispatcher state (redirect case)
    if @actionDeferred?
      @actionDeferred = null
      actionDeferred.reject { abort: true }

    # Deactivate all newly created/refreshed compositions
    @deactivateCompositions()

    # Save generated unique id for current dispatcher state
    @currentStateId = _.uniqueId('dispatcher_state_')

  afterAction: ->
    actionDeferred = @actionDeferred

    # Action method is done; perform post-action clean up
    @cleanup()

    # Resolve action deferred object (if presents)
    # to trigger async composition execution
    if actionDeferred?
      @actionDeferred = null
      actionDeferred.resolve()

    # Wait for all async compositions
    waitForComposePromise = @_waitForCompose()
    waitForComposePromise.then (success) =>
      # Dispatch event when all compositions are ready
      @publishEvent 'composer:complete', success
    , ->
      return

  deactivateCompositions: ->
    # Declare all active compositions as deactivated (eg. to be removed
    # on the next controller startup unless they are re-composed).
    for name, composition of @compositions
      composition.stale true

    # Return nothing.
    return

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

    @deactivateCompositions()

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
