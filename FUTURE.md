# Semel R1

## Planning and strategy

- Fix issue of tests not being runnable in root project in xcode
- Plugin arch so that others (and ai) can add toolchains like c++
- Fix: when node added to output fs, writes to console

- Fix: when copying out an executable file, it should have the +x attribute (libs also?)

- Make github repo public

- Convert to client-server architecture and daemon
- Clearly delineate Core, DatabaseModels, CLI, SemelServ

- Get it working with large c or c++ project
- Get it working with large swift package similar to a kit

- Better integration tests that cover situations where for example an input file is created but then deleted and a number of nodes should also be deleted

- Solve the problem of code changes invalidating the entire cache and database. 

- Database migration: export all input files, upgrade, then import all

- Cache integrity check: compare the cache with computed output and if they differ, reset the entire cache.

- Also a command to reset and rebuild the graph. Deletes all nodes that are not folders, projectfinder, or staticfiles in the inputfs, then lets projectfinder re-find everything and rebuild the graph. This also helps with dev since we don’t have to rename db every time.
