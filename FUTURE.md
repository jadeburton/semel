# Semel R1

## Planning and strategy

- Fix issue of tests not being runnable in root project in xcode
- Fix: when node added to output fs, writes to console. Currently false positives caused by branches being deleted and recreated; output files disappear briefly.

- Clearly delineate Core, DatabaseModels, CLI, SemelServ
- Convert to client-server architecture and daemon

- Central cache server 

- Get it working with large swift package that has complicated dependencies and targets

- Get it working with large c or c++ project

- Maybe, if at all technically possible, a tool to convert a makefile or cmake file to a Formula file. Or even a Node that does it. Technically this is trying to convert imperative code to functional, but a "pure" makefile can in fact be functional. Cmake still has add_xxx methods and a mess of a syntax.

- Make github repo public

- Remote execution of tools. Ideally in docker containers running wherever.

- Solve the problem of code changes invalidating the entire cache and database. I.e. Semel code itself should have some kind of hash over it and this is used to invalidate caches. 

- Periodic cache integrity check: randomly compare the cache with computed output and if they differ, reset the entire cache.

- Database migration: probably just clear all caches and rebuild everything

- Rollback of all input file changes if any Node enters an error state as a result, thus guaranteeing the build is always green.

- Plugin arch so that others (and ai) can add toolchains like c++
