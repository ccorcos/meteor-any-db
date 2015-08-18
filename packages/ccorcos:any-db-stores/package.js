Package.describe({
  name: 'ccorcos:any-db-stores',
  summary: 'A flux-like architecture for Meteor and ccorcos:any-db',
  version: '0.0.1',
  git: 'https://github.com/ccorcos/meteor-any-db'
});

Package.onUse(function(api) {
  api.versionsFrom('1.0');

  api.use(['coffeescript', 'http', 'ccorcos:any-db-pub-sub@0.0.1']);
  api.imply(['http'])
  api.add_files(['src/stores.coffee'])
  api.add_files(['src/globals.js'])
  api.export([
    'createRESTStore',
    'createRESTListStore',
    'createDDPStore',
    'createDDPListStore',
    'createCache'
  ])
});
