Package.describe({
  name: 'ccorcos:db',
  summary: 'Database API for Meteor',
  version: '0.0.1',
  git: 'https://github.com/ccorcos/meteor-db'
});

Package.onUse(function(api) {
  api.versionsFrom('1.0');
  both = ['client', 'server']
  api.use([
    'coffeescript', 
    'ramda:ramda@0.13.0',
    'diff-sequence',
    'random',
    // 'mongo-id'
  ], both);

  api.addFiles('src/driver.coffee', both);
});
