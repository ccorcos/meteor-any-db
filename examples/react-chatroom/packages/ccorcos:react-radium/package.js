Package.describe({
  name: 'ccorcos:react-radium',
  summary: 'React and Radium for Meteor',
  version: '0.0.1',
  git: 'https://github.com/ccorcos/'
});


Package.onUse(function(api) {
  api.versionsFrom('1.0');
  api.addFiles('pre.js', 'client');
  api.addFiles('vendor/react.js', 'client');
  api.addFiles('post-react.js', 'client');
  api.export('React', 'client')
  
  api.addFiles('pre.js', 'client');
  api.addFiles('vendor/radium.js', 'client');
  api.addFiles('post-radium.js', 'client');
  api.export('Radium', 'client')
});
