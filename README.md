# Meteor Any-DB

This package allows you to use Meteor with any **database** or **data source**.

# Getting Started

Simply add this package to your project:

    meteor add ccorcos:any-db

This is just a meta package. Check out the README files for the individual packages.

# Tests

Definitely need tests...

#### pub-sub

- cursor unordered
- cursor ordered
- noncursor unordered
- noncursor ordered

- added, changed, moved, removed, cleared

#### stores

- get, fetch, clear, (cache)...
make sure we're counting how many get/clears correctly
- get, fetch, get, clear, ... (still there), clear, (cache)...
