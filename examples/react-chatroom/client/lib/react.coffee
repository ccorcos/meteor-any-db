
# React components
Views = {}
Controller = {}
createView = compose(React.createFactory, Radium, React.createClass)

# Global state
@State = {}

# Create a new object
shallowClone = (obj) ->
  newObj = {}
  for key, value of obj
    newObj[key] = value
  return newObj

isPlainObject = (x) ->
  Object.prototype.toString.apply(x) is "[object Object]"

isFunction = (x) ->
  Object.prototype.toString.apply(x) is "[object Function]"


# Whatever changes must have a new reference, everything else
# has the same reference to optimize for React with PureRender 
# which checks object reference equality.
evolve = curry (dest, obj) ->
  newDest = shallowClone(dest)
  for k,v of obj
    if isPlainObject(v)
      newDest[k] = evolve(newDest[k], v)
    else if isFunction(v)
      newDest[k] = v(newDest[k])
    else
      newDest[k] = v
  return newDest

# Similar to evolve but uses a predicate over an array
evolveWhere = curry (pred, evolution, list) ->
  map((element) ->
    if pred(element) then evolve(element, evolution) else element
  , list)

# This is a main function we use that has side-effects
evolveState = (evolution) ->
  @State = evolve(@State, evolution)

blurOnEnterTab = (e) ->
  if e.key is "Tab" or e.key is "Enter"
    # we have to prevent default in order to 
    # focus immediately on th next one.
    e.preventDefault()
    $(e.target).blur()
  return e

CSSTransitionGroup = React.createFactory(React.addons.CSSTransitionGroup)

_.extend(this, {
  Views
  Controller
  createView
  shallowClone
  evolve
  evolveWhere
  evolveState
  blurOnEnterTab
  CSSTransitionGroup
})
