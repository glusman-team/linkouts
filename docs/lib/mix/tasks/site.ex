defmodule Mix.Tasks.Site do
  @moduledoc """
  Builds the documentation site: `mix docs`, but over the web app's modules.

      mix site [--warnings-as-errors]

  ExDoc documents the current project's compiled modules, and this project has none of its own —
  the API worth documenting lives in `web/`, which is a path dependency here. `mix docs` therefore
  produces guides with an empty API section. This task runs the same ExDoc entry point with the
  dependency's ebin as the source, using `Mix.Tasks.Docs.run/3`'s generator argument rather than
  forking ExDoc, so upgrades keep working.
  """
  use Mix.Task

  @shortdoc "Builds the ExDoc site over the web app's modules"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    web_ebin = Path.join([Mix.Project.build_path(), "lib", "edge_linkouts", "ebin"])

    unless File.dir?(web_ebin) do
      Mix.raise("""
      #{web_ebin} does not exist, so there are no modules to document.

      Fetch and compile the web app first:  cd docs && mix deps.get && mix compile
      """)
    end

    generator = fn project, version, _own_beams, options ->
      ExDoc.generate(project, version, [web_ebin], options)
    end

    Mix.Tasks.Docs.run(args, Mix.Project.config(), generator)
  end
end
