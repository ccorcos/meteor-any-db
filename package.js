Package.describe({
  name: 'ccorcos:any-db',
  summary: 'Publish and subscribe ordered collections.',
  version: '0.1.0',
  git: 'https://github.com/ccorcos/meteor-any-db'
});

Package.onUse(function(api) {
  api.versionsFrom('1.2');

  api.use([
    'coffeescript',
    'random',
    'id-map',
    'diff-sequence',
    'meteorhacks:unblock@1.1.0',
    'ccorcos:utils@0.0.1'
  ]);

  api.addFiles(['globals.js']);
  api.addFiles(['pub.coffee'], 'server');
  api.addFiles(['sub.coffee'], 'client');
  
  api.export(['AnyDb']);
});
