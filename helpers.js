var { U, R } = require('./utils.js');

module.exports = {
  parseDDPMsg: parseDDPMsg,
  findDocIdIndex: findDocIdIndex,
  changeDoc: changeDoc
};

// TODO: ANNOTATE THIS
/**
 * 
 */
function parseDDPMsg(data) {
  let id = parseId(data.id);
  // what do these fields look like
  data.fields = fields2Obj(data.fields);
  let positions = {};
  let cleared = {};
  // wtf is subobj
  let subObj = data.fields[this.DB_KEY];

  if (subObj) {
    for (let subId in subObj) {
      // wtf is subId and value???
      let value = subObj[subId];
      if (value === undefined) {
        cleared[subId] = true
      } else {
        let before = value.split('.')[1];
        if (before === 'null') { before = null }
        positions[subId] = before
      }
    }
  }
  let fields = R.clone(data.fields)
  delete fields[this.DB_KEY]
  return {
    id: id, 
    fields: fields,
    positions: positions,
    cleared: cleared
  };
}

// this would be modified if switching to minimongo
/**
 * finds index of a document by its id
 */
function findDocIdIndex(id, docs) {
  for (let i = 0; i < docs.length; i++) {
    if (docs[i]._id === id) {
      return i;
    }
  }
  return -1;
}

/**
 * 
 */
function changeDoc(doc, fields) {
  return deleteUndefined(U.extendDeep(doc, fields));
}

/***********************************************/
/*                   helpers                   */
/***********************************************/

// TODO: ANNOTATE THIS
/**
 * unflatten DDP fields into a deep object
 * e.g. any-db.1: value >> any-db: {1: value}
 */
function fields2Obj(fields) {
  fields = fields || {};
  fields = R.clone(fields);
  let dest = {};
  for (let key in fields) {
    let value = fields[key];
    let keys = key.split('.').reverse();
    if (keys.length === 1) {
      dest[key] = value;
    } else {
      let obj = {};
      let prevObj = obj;
      while (keys.length > 1) {
        let tmp = {};
        prevObj[keys.pop()] = tmp;
        prevObj = tmp;
      }
      prevObj[keys.pop()] = value;
      U.extendDeep(dest, obj);
    }
  }
  return dest;
}

// TODO: annotate this
function parseId(id) {
  if (id === '-') {
    return undefined;
  } else if (id.substr(0, 1) === '-') {
    return id.substr(1);
  } else if (id.substr(0, 1) === '~') {
    return JSON.parse(id.substr(1)).toString();
  } else {
    // if id === '' or something else entirely
    return id;
  }
}

/**
 * removes fields that are set to undefined
 */
function deleteUndefined(doc) {
  for (let key in doc) {
    let value = doc[key];
    if (U.isPlainObject(value)) {
      // why are we setting the key to undefined??
      doc[key] = deleteUndefined(value);
    } else if (value === undefined) {
      delete doc[key];
    }
  }
  return;
}
