shader_type spatial;
render_mode world_vertex_coords, cull_disabled;
#include "weather_globals.gdshaderinc"

void vertex() {
    VERTEX += tree_bend(VERTEX);
}
