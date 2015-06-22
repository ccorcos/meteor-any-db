# Meteor Neo4j

This package will allow you to use the open-source graph database Neo4j with your Meteor project. If you are mapping relationships, this database will be much more efficient than the built-in Mongo database. You can run it both locally and with [GrapheneDB](http://www.graphenedb.com/) for production.

## Installation and setup

You will have to install Neo4j globally on your machine. It is also important to note that you must start up Neo4j independently of Meteor every time you want to use it using the command `neo4j start`. Install Neo4j with the following command:

    brew install neo4j
    npm install -g neo4j

Then start Neo4j and start Meteor:

    neo4j start
    meteor add ccorcos:neo4j
    meteor

## How to use

You should be able to see the Neo4j browser at the Neo4j url (default: http://localhost:7474/). Neo4j provides you with a pretty nice user interface to play around with and test out your cypher queries.

When you're done, be sure to stop Neo4j as well, otherwise it will run in the background forever:

    neo4j stop

Sometimes it hangs and won't stop. Try `ps aux | grep neo4j` and then `kill -9 <pid>`.

To reset Neo4j, delete `data/graph.db`. If you used brew to install Neo4j, then the path will be similar to the following:

    rm -rf /usr/local/Cellar/neo4j/2.1.7/libexec/data/graph.db

Or you can use the following queries to delete all relationships and all nodes

    match ()-[r]->(), (n) delete r,n

Or you can use the `.reset` method attached to the Neo4j object. This is much slower though.

To instatiate a connection, on the server, use:

    Neo4j = new Neo4jDB()

Also note, that Neo4j does not accept nested property lists, so its best to structure your Mongo collections similarly.

If you intend to use GrapheneDB, first you must set up an account through their website and obtain your url, username, and password. Then, you have two options for initializing GrapheneDB: passing a url or setting the GRAPHENEDB_URL environment variable. We will go over both options.

## Connecting with GrapheneDB

Your first option is to pass a url when you instantiate a connection. The format is as follows:

    Neo4j = new Neo4jDB(http://<USERNAME>:<PASSWORD>@projectname.sb05.stations.graphenedb.com:24789)
    
GrapheneDB provides you with the username, password and the url. Your best bet is to put your username and password into a `settings.json` so you don't expose your username and password, but that's your call.

Your other option is to instantiate the connection as you normally would, but set GRAPHENEDB_URL on startup:
    
    Meteor.startup ->
      process.env.GRAPHENEDB_URL = "http://<USERNAME>:<PASSWORD>@projectname.sb05.stations.graphenedb.com:24789"

The Neo4j constructor will select the `url` over everything else, so if there are conflicts, it will default to the url you pass. It only runs on `localhost:7474` if it has no other options.

## Querying

Neo4j uses a querying language called `Cypher`, which is pretty similar to SQL. They have a lot of [documentation](http://neo4j.com/docs/stable/cypher-query-lang.html) that is probably worth reviewing. This package uses a very simple implementation of Cypher, which simply passes a string with your query.

    result = Neo4j.query "MATCH (a) RETURN a"
    
You can also write multi-line queries, which are generally easier to read:

    result = Neo4j.query """
               MATCH (a)
               RETURN a
               """

## Examples

*Coming soon!*
