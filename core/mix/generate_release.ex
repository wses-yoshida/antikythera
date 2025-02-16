# Copyright(c) 2015-2019 ACCESS CO., LTD. All rights reserved.

defmodule Mix.Tasks.AntikytheraCore.GenerateRelease do
  @shortdoc "Generates a new release tarball for antikythera instance using relx"

  @moduledoc """
  #{@shortdoc}.

  Notes on the implementation details of this task:

  - Release generation is basically done under `rel_erlang-*/`.
    During tests (i.e. when `ANTIKYTHERA_COMPILE_ENV=local`), files are generated under `rel_local_erlang-*/`.
      - Erlang/OTP major version number is included in the path in order to distinguish artifacts generated by different OTP releases.
        No binary compatibility is maintained by major version release of Erlang/OTP due to precompilation of Elixir's regex sigils.
        For more details see [documentation for Regex module](https://hexdocs.pm/elixir/Regex.html#module-precompilation).
  - Generated releases are placed under `rel(_local)_erlang-*/<antikythera_instance>/releases/`.
  - If no previous releases found, this task generates a new release from scratch (i.e. without relup).
    If any previous releases exist, relup file to upgrade from the latest existing release to the current release is also generated.
  - Making a new release tarball consists of the following steps:
      - Preparation
          - `.beam` and `.app` files.
          - `vm.args`: resides in the git repository and is copied to the release by relx's overlay mechanism.
          - `sys.config`: generated from mix config and then copied to the release by relx's overlay mechanism.
          - `relx.config`: generated from `relx.config.eex`.
      - Release generation
          - If needed, generate .appup files and relup file.
          - Generate a new release from the input files by `:relx.do/2`.
      - Cleanup
          - Move some files and apply patch to boot script, in order to suit our needs.
          - Make a tarball. This step also uses `:relx.do/2`.
          - Remove temporary files.
  """

  use Mix.Task
  alias AntikytheraCore.Release.Appup

  @release_output_dir_basename (if Antikythera.Env.compile_env() == :local, do: "rel_local", else: "rel") <> "_erlang-#{System.otp_release()}"
  antikythera_repo_rel_dir = Path.expand(Path.join([__DIR__, "..", "..", "rel"]))
  boot_script_patch_name   = if Antikythera.Env.compile_env() == :prod, do: "boot_script.patch", else: "boot_script.dev.patch"
  @vm_args_path              Path.join(antikythera_repo_rel_dir, "vm.args")
  @boot_script_patch_path    Path.join(antikythera_repo_rel_dir, boot_script_patch_name)
  @relx_config_template_path Path.join(antikythera_repo_rel_dir, "relx.config.eex")

  def run(_args) do
    conf = Mix.Project.config()
    release_name = conf[:app]
    if release_name == :antikythera, do: Mix.raise("Application name of an antikythera instance must not be `:antikythera`")
    version = conf[:version]
    setup(release_name, version, fn relx_config_path ->
      do_generate(release_name, version, relx_config_path)
    end)
  end

  defp setup(release_name, version, f) do
    File.mkdir_p!(@release_output_dir_basename)
    sys_config_path  = Path.join(@release_output_dir_basename, "sys.config")
    relx_config_path = Path.join(@release_output_dir_basename, "relx.config")
    try do
      ensure_antikythera_instance_compiled()
      prepare_sys_config(sys_config_path)
      prepare_relx_config(release_name, version, relx_config_path)
      f.(relx_config_path)
    after
      File.rm!(relx_config_path)
      File.rm!(sys_config_path)
    end
  end

  defp ensure_antikythera_instance_compiled() do
    try do
      # Generate <antikythera_instance>.app as it can be for older version of the instance.
      :ok = Mix.Tasks.Compile.App.run(["--force"])
    rescue
      File.Error ->
        # Directory for <antikythera_instance>.app does not exist,
        # i.e. the antikythera instance is not yet compiled; run the normal compilation.
        Mix.Tasks.Compile.run([])
    end
  end

  defp prepare_sys_config(sys_config_path) do
    {config, _} = Mix.Config.eval!(Mix.Project.config()[:config_path])
    pretty_config_str = :io_lib.fwrite('~p.\n', [config]) |> List.to_string()
    File.write!(sys_config_path, pretty_config_str)
    IO.puts("Generated #{sys_config_path}.")
  end

  defp prepare_relx_config(release_name, version, relx_config_path) do
    bindings = [release_name: release_name, release_version: version, lib_dirs: lib_dirs(), vm_args_path: @vm_args_path]
    file_content = EEx.eval_file(@relx_config_template_path, bindings)
    File.write!(relx_config_path, file_content)
    IO.puts("Generated #{relx_config_path}.")
  end

  defp lib_dirs() do
    [
      Path.join([Mix.Project.build_path(), "lib"]),
      Path.join(:code.lib_dir(:elixir ), "ebin") |> Path.expand(),
      Path.join(:code.lib_dir(:iex    ), "ebin") |> Path.expand(),
      Path.join(:code.lib_dir(:eex    ), "ebin") |> Path.expand(),
      Path.join(:code.lib_dir(:mix    ), "ebin") |> Path.expand(),
      Path.join(:code.lib_dir(:logger ), "ebin") |> Path.expand(),
      Path.join(:code.lib_dir(:ex_unit), "ebin") |> Path.expand(),
    ]
  end

  defp do_generate(release_name, version, relx_config_path) do
    release_output_dir = Path.expand(@release_output_dir_basename)
    case existing_release_versions(release_name, release_output_dir) do
      []               -> generate_from_scratch(release_name, version, relx_config_path, release_output_dir)
      release_versions ->
        if version in release_versions do
          IO.puts("Version '#{version}' already exists.")
        else
          # Only support upgrade from the latest existing version
          latest_existing = Enum.sort(release_versions) |> List.last()
          if latest_existing >= version do
            Mix.raise("Existing latest release (#{latest_existing}) must precede the current version (#{version})!")
          end
          generate_with_upgrade(release_name, version, latest_existing, relx_config_path, release_output_dir)
        end
    end
  end

  defp existing_release_versions(release_name, release_output_dir) do
    releases_dir = Path.join([release_output_dir, Atom.to_string(release_name), "releases"])
    case File.ls(releases_dir) do
      {:error, _}  -> []
      {:ok, files} -> files -- ["RELEASES", "#{release_name}.rel", "start_erl.data"]
    end
    |> Enum.filter(fn release_version ->
      File.exists?(Path.join([releases_dir, release_version, "#{release_name}.tar.gz"]))
    end)
  end

  defp generate_from_scratch(release_name, version, relx_config_path, release_output_dir) do
    IO.puts("Generating release #{version} without upgrade ...")
    run_relx(release_name, version, false, relx_config_path, release_output_dir)
  end

  defp generate_with_upgrade(release_name, version, from_version, relx_config_path, release_output_dir) do
    IO.puts("Generating release #{version} with upgrade instruction from #{from_version} ...")
    generate_appup_files(release_name, version, from_version, release_output_dir)
    run_relx(release_name, version, true, relx_config_path, release_output_dir)
  end

  defp run_relx(release_name, version, upgrade?, relx_config_path, release_output_dir) do
    relx_opts = [
      log_level:  2,
      root_dir:   String.to_charlist(File.cwd!()),
      config:     String.to_charlist(relx_config_path),
      relname:    release_name,
      relvsn:     String.to_charlist(version),
      output_dir: String.to_charlist(release_output_dir),
      dev_mode:   false,
    ]
    release_name_str = Atom.to_string(release_name)
    generate_release_and_relup(release_name_str, version, upgrade?, release_output_dir, relx_opts)
    finalize_release_as_tarball(release_name_str, version, release_output_dir, relx_opts)
  end

  defp generate_release_and_relup(release_name_str, version, upgrade?, release_output_dir, relx_opts) do
    commands = if upgrade?, do: ['release', 'relup'], else: ['release']
    {:ok, _} = run_relx_impl(relx_opts, commands)
    remove_versioned_boot_script(release_name_str, version, release_output_dir)
    apply_patch_to_boot_script(release_name_str, release_output_dir)
    if upgrade? do
      move_relup(release_name_str, version, release_output_dir)
    end
  end

  defp finalize_release_as_tarball(release_name_str, version, release_output_dir, relx_opts) do
    {:ok, _} = run_relx_impl(relx_opts, ['tar'])
    move_tarball(release_name_str, version, release_output_dir)
  end

  defp run_relx_impl(relx_opts, commands) do
    # :relx is a :prod-only dependency and thus we use `apply/3` to suppress warning
    # (note that when compiling antikythera from within an antikythera instance or gear project,
    # `Mix.env()` returns `:prod` but :prod-only deps are not available).
    apply(:relx, :do, [relx_opts, commands])
  end

  defp generate_appup_files(release_name, rel_version, from_rel_version, release_output_dir) do
    current_deps = Mix.Dep.load_on_environment(env: Mix.env()) |> Enum.map(&dep_struct_to_triplet/1)
    release_name_str = Atom.to_string(release_name)
    instance_otp_app = {release_name, rel_version, Path.join([Mix.Project.build_path(), "lib", release_name_str])}
    current_otp_apps = [instance_otp_app | current_deps]
    prev_otp_apps = read_rel_file(release_name_str, from_rel_version, release_output_dir)
    generate_appup_files_impl(release_name_str, current_otp_apps, prev_otp_apps, release_output_dir)
  end

  defp generate_appup_files_impl(release_name_str, current_otp_apps, prev_otp_apps, release_output_dir) do
    Enum.each(current_otp_apps, fn {name, version, dir} ->
      case prev_otp_apps[name] do
        nil          -> :ok
        ^version     -> :ok
        prev_version ->
          prev_dir = Path.join([release_output_dir, release_name_str, "lib", "#{name}-#{prev_version}"])
          Appup.make(name, prev_version, version, prev_dir, dir)
          IO.puts("Generated #{name}.appup.")
      end
    end)
  end

  defp dep_struct_to_triplet(%Mix.Dep{app: name, opts: opts}) do
    dir = opts[:build]
    version = AntikytheraCore.Version.read_from_app_file(dir, name)
    {name, version, dir}
  end

  defp read_rel_file(release_name_str, version, release_output_dir) do
    rel_file_path = Path.join([release_output_dir, release_name_str, "releases", version, "#{release_name_str}.rel"])
    release_name_chars = String.to_charlist(release_name_str)
    {:ok, [{:release, {^release_name_chars, _}, {:erts, _}, deps}]} = :file.consult(rel_file_path)
    Map.new(deps, fn
      {name, version}    -> {name, List.to_string(version)}
      {name, version, _} -> {name, List.to_string(version)}
    end)
  end

  defp remove_versioned_boot_script(release_name_str, version, release_output_dir) do
    File.rm!(Path.join([release_output_dir, release_name_str, "bin", "#{release_name_str}-#{version}"]))
  end

  defp apply_patch_to_boot_script(release_name_str, release_output_dir) do
    # Currently "rel/boot_script.patch" contains 3 hunks:
    # - specify `-mode interactive` emulator flag (instead of `embed`) for easier module loading
    # - enable iex in remote_console
    # - automatically start iex on start (which enables auto-completion in remote_console)
    script_path = Path.join([release_output_dir, release_name_str, "bin", release_name_str])
    {_, 0} = System.cmd("patch", ["--backup-if-mismatch", script_path, @boot_script_patch_path])
    if File.exists?("#{script_path}.orig") do # patch command generated a backup
      Mix.raise("Patch for #{script_path} does not match exactly. Fix the patch to catch up with relx's boot script.")
    end
  end

  defp move_relup(release_name_str, version, release_output_dir) do
    source = Path.join([release_output_dir, release_name_str, "relup"])
    dest   = Path.join([release_output_dir, release_name_str, "releases", version, "relup"])
    move_across_partitions(source, dest)
  end

  defp move_tarball(release_name_str, version, release_output_dir) do
    source = Path.join([release_output_dir, release_name_str, "#{release_name_str}-#{version}.tar.gz"])
    dest   = Path.join([release_output_dir, release_name_str, "releases", version, "#{release_name_str}.tar.gz"])
    move_across_partitions(source, dest)
  end

  defp move_across_partitions(source, dest) do
    File.copy!(source, dest)
    File.rm!(source)
  end
end
