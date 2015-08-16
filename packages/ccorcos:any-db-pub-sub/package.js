Package.describe({
  name: 'ccorcos:any-db-pub-sub',
  summary: 'publish and subscribe for ccorcos:any-db',
  version: '0.0.1',
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
  api.addFiles('src/pub-sub.coffee');
  api.addFiles('src/globals.js');
  api.export(['publish', 'refreshPub', 'pubs'], 'server');
  api.export(['subscribe', 'subs'], 'client');
});
