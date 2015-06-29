Package.describe({
  name: 'ccorcos:any-db',
  summary: 'A database API for Meteor',
  version: '0.0.1',
  git: 'https://github.com/ccorcos/meteor-any-db'
});

Package.onUse(function(api) {
  api.versionsFrom('1.0');
  both = ['client', 'server']

  // until the next version of meteor comes out
  api.export('DiffSequence');
  api.use(['underscore', 'ejson']);
  api.addFiles([
    'diff.js'
  ]);

  api.export('DB');
  api.use([
    'coffeescript', 
    'ramda:ramda@0.13.0',
    // 'diff-sequence',
  ], both);
  api.addFiles('src/db.coffee', both);
});
