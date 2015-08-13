Package.describe({
  name: 'ccorcos:any-db',
  summary: 'A database API for Meteor',
  version: '0.1.0',
  git: 'https://github.com/ccorcos/meteor-any-db'
});

Package.onUse(function(api) {
  api.versionsFrom('1.0');

  // until the next version of meteor comes out
  api.export('DiffSequence');
  api.use(['underscore', 'ejson']);
  api.addFiles([
    'diff.js'
  ]);

  api.use(['coffeescript', 'random', 'id-map']);
  api.addFiles('src/db.coffee');
  api.addFiles('src/globals.js');
  api.export(['publish', 'refreshPub'], 'server');
  api.export('subscribe', 'client');
});
