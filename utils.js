/********************************************/
/*     copied from ccorcos:meteor-utils     */
/* https://github.com/ccorcos/meteor-utils/ */
/********************************************/
var R = require('ramda');
var U = require('underscore');

U.unix = function() {
  return Math.round(Date.now() / 1000);
};

U.timestamp = function() {
  return Date.now();
};

U.stopwatch = function() {
  var start = U.timestamp();
  return function() {
    return (U.timestamp - start) / 1000;
  }
};

U.isPlainObject = function(x) {
  return Object.prototype.toString.apply(x) === '[object Object]';
};

U.extendDeep = R.curry(function(dest, obj) {
  for (var k in obj) {
    var v = obj[k];
    if (U.isPlainObject(v)) {
      dest[k] = dest[k] || {};
      U.extendDeep(dest[k], v);
    } else {
      dest[k] = v;
    }
  }
});

module.exports = { U, R };