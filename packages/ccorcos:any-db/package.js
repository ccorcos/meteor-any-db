Package.describe({
  name: 'ccorcos:any-db',
  summary: 'Any database with Meteor',
  version: '0.1.0',
  git: 'https://github.com/ccorcos/meteor-any-db'
});

Package.onUse(function(api) {
  api.versionsFrom('1.0');

  packages = ['ccorcos:any-db-stores@0.0.1']
  api.use(packages)
  api.imply(packages)

});
