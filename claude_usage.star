"""Claude subscription usage limits as radial gauges."""

load("render.star", "render")
load("schema.star", "schema")

def main(config):
    return render.Root(
        child = render.Text("CLAUDE"),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "token",
                name = "OAuth token",
                desc = "Token from `claude setup-token` (sk-ant-oat01-...)",
                icon = "key",
            ),
            schema.Toggle(
                id = "show_reset",
                name = "Show reset countdown",
                desc = "Top row shows time until the tightest limit resets",
                icon = "clock",
                default = True,
            ),
        ],
    )
