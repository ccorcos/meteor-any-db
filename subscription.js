let { U, R } = require('./utils.js');
let {
  changeDoc,
  findDocIdIndex
} = require('./helpers.js');

let random = new require('random-js')();

class Subscription {
  constructor(name, query, anyDb, onReady) {
    this.name = name;
    this.query = query;
    this.anyDb = anyDb;
    this.ddp = anyDb.ddp;

    this.data = [];
    this.dataIds = {};
    this.ready = false;

    // onChange listeners, invoked when anything is added, removed or changed in associated collections
    this.listeners = {};

    // TODO: what do we use this for?
    var lap = U.stopwatch();
    
    // TODO: sub.coffee line 97
    // do we need to wrap this in Tracker.nonreactive??
    // TODO: does the query need to be wrapped in an Array?
    this.subId = this.ddp.subscribe(name, [query], (err) => {
      if (err) {
        console.log('error subscribing to:', name, err);
        return err;
      }
      this.ready = true;
      this._dispatchChange();
      return typeof onReady === "function" ? onReady(this) : void 0;
    });

    // TODO: will handling tracking of the sub here result in a memory leak?
    // add this subscription to our anyDb's subs
    this.anyDb.subs[this.subId] = this;
  }

  /* these would be modified if switching to minimongo */
  // TODO: could `fields` be renamed to something more descriptive?
  addedBefore(id, fields, before) {
    let doc = fields;
    doc._id = id;
    this.dataIds[id] = true;
    if (before === null) {
      this.data = this.data.concat(doc);
    } else {
      let index = findDocIdIndex(before, this.data);
      if (index < 0) { throw new Error('Expected to find before id', before); }
      this.data = R.clone(sub.data);
      this.data.splice(i, 0, doc);
    }
    this._dispatchChange();
  }

  movedBefore(id, before) {
    let fromIndex = findDocIdIndex(id, this.data);
    if (fromIndex < 0) { throw new Error('Expected to find id', id); }
    this.data = R.clone(this.data);
    doc = this.data[fromIndex];
    this.data.splice(fromIndex, 1);
    if (before === null) {
      this.data.push(doc);
    } else {
      let toIndex = findDocIdIndex(before, this.data);
      if (toIndex < 0) { throw new Error('Expected to find before id', before); }
      this.data.splice(toIndex, 0, doc);
    }
    this._dispatchChange();
  }

  changed(id, fields) {
    this.data = R.clone(this.data);
    let index = findDocIdIndex(id, this.data);
    if (index < 0) { throw new Error('Expected to find id', id); }
    changeDoc(this.data[id], fields);
    this._dispatchChange();
  }

  removed(id) {
    let index = findDocIdIndex(id, this.data);
    if (index < 0) { throw new Error('Expected to find id', id); }
    // currently unused
    let oldDoc = this.data.splice(index, 1)[0];
    delete this.dataIds[id];
    this._dispatchChange();
  }

  stop() {
    this.listeners = {};
    // handle.stop();   // original
    // TODO: how do we stop the ddp subscriptions?
    this.ddp.unsubscribe(this.subId);
    this.data = [];
    this.dataIds = {};
  }

  reset() {
    this.data = [];
    this.dataIds = {};
    // this._dispatchChange();
  }

  /** 
   * Sets a listener to be run the entire subscription's dataset when the subscription data changes
   * returns an object
  */
  onChange(listener) {
    let self = this;
    let id = random.hex(10);
    self.listeners[id] = listener;
    return {
      stop: () => {
        return delete self.listeners[id];
      }
    };
  }

  // calls a listener with the entire subscription's data
  _dispatchChange() {
    if (!this.ready) { return; }
    for (let id in this.listeners) {
      this.listeners[id](R.clone(this.data));
    }
  }
}

module.exports = Subscription;
