## Emits the JS wire-constants block (src/magent/wire_constants.nim) on stdout.
## The static replay-viewer bundle cannot run the server's compile-time splice,
## so Dockerfile.replay-viewer runs this to write dist/wire_constants.js and
## injects a <script src> for it into the bundled page -- same constants, same
## source, different delivery.
import ../src/magent/wire_constants

echo WireConstantsJs
