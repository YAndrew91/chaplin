'use strict'

_ = require 'underscore'
Backbone = require 'backbone'
EventBroker = require 'chaplin/lib/event_broker'

has = Object::hasOwnProperty

# Composition
# -----------

# A utility class that is meant as a simple proxied version of a
# controller that is used internally to inflate simple
# calls to !composer:compose and may be extended and used to have complete
# control over the composition process.
module.exports = class Composition
  # Borrow the static extend method from Backbone.
  @extend = Backbone.Model.extend

  # Mixin Backbone events and EventBroker.
  _.extend @prototype, Backbone.Events
  _.extend @prototype, EventBroker

  # The item that is composed; this is by default a reference to this.
  item: null

  # The options that this composition was constructed with.
  options: null

  # The array of composition names which this composition depends from
  dependencies: null

  # Whether this composition is currently stale.
  _stale: false

  # Reference to promise for asynchronous compose operation
  # (until it's in progress)
  promise: null

  constructor: (options) ->
    @options = _.extend {}, options if options?
    @item = this
    @dependencies = []
    @initialize @options

  initialize: ->
    # Empty per default.

  # The compose method is called when this composition is to be composed.
  compose: ->
    # Empty per default.

  # The update method is called when this composition is to be composed
  # or updated.
  update: ->
    # Empty per default.

  # The error method is called when this composition is failed.
  # If returns promise - execution is continued; otherwise composition
  # is removed from composer
  error: ->
    # Empty per default.

  # The afterDispose method is called after this composition is disposed.
  afterDispose: ->
    # Empty per default.

  # The check method is called when this composition is asked to be
  # composed again. The passed options are the newly passed options.
  # If this returns false then the composition is re-composed.
  check: (options) ->
    _.isEqual @options, options

  # Marks all applicable items as stale.
  stale: (value) ->
    # Return the current property if not requesting a change.
    return @_stale unless value?

    # Sets the stale property for every item in the composition that has it.
    @_stale = value
    for name, item of this when (
      item and item isnt this and
      typeof item is 'object' and has.call(item, 'stale')
    )
      item.stale = value

    # Return nothing.
    return

  # Disposal
  # --------

  disposed: false

  dispose: ->
    return if @disposed

    # Dispose and delete all members which are disposable.
    for own prop, obj of this when obj and typeof obj.dispose is 'function'
      unless obj is this
        obj.dispose()
        delete this[prop]

    # Unbind handlers of global events.
    @unsubscribeAllEvents()

    # Unbind all referenced handlers.
    @stopListening()

    # Remove properties which are not disposable.
    properties = ['redirected']
    delete this[prop] for prop in properties

    # Finished.
    @disposed = true

    # You're frozen when your heart’s not open.
    Object.freeze? this
