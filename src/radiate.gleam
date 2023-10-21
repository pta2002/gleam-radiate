import filespy
import gleam/io
import shellout
import gleam/string
import gleam/list

/// Phantom type to indicate no directories are added
pub type NoDirectories

/// Phantom type to indicate directories have been added
pub type HasDirectories

/// Opaque builder type for reloader. Create with `new`.
pub opaque type Builder(has_dirs) {
  Builder(dirs: List(String), callbacks: List(fn(String) -> Nil))
}

/// Construct a new builder
pub fn new() -> Builder(NoDirectories) {
  Builder(dirs: [], callbacks: [])
}

pub fn add_dir(
  builder: Builder(has_dirs),
  dir: String,
) -> Builder(HasDirectories) {
  Builder(dirs: [dir, ..builder.dirs], callbacks: builder.callbacks)
}

/// Add a callback to be run after reload
pub fn on_reload(
  builder: Builder(has_dirs),
  callback: fn(String) -> Nil,
) -> Builder(has_dirs) {
  Builder(dirs: builder.dirs, callbacks: [callback, ..builder.callbacks])
}

type Module

type What

@external(erlang, "code", "modified_modules")
fn modified_modules() -> List(Module)

@external(erlang, "code", "purge")
fn purge(module: Module) -> Bool

@external(erlang, "code", "atomic_load")
fn atomic_load(modules: List(Module)) -> Result(Nil, List(#(Module, What)))

/// Start reloader
pub fn start(builder: Builder(HasDirectories)) {
  filespy.new()
  |> filespy.add_dirs(builder.dirs)
  |> filespy.set_handler(fn(path, event) {
    case event {
      filespy.Closed -> {
        // Check if path ends in '.gleam'
        case string.ends_with(path, ".gleam") {
          True -> {
            // Rebuild
            let build_result =
              shellout.command(["build"], run: "gleam", in: ".", opt: [])

            case build_result {
              Ok(_output) -> {
                let mods = modified_modules()
                list.each(mods, purge)
                let _ = atomic_load(mods)

                list.each(builder.callbacks, fn(callback) { callback(path) })

                Nil
              }
              Error(#(_status, message)) -> {
                message
                |> io.print_error
              }
            }
          }
          _ -> Nil
        }
      }
      _ -> Nil
    }
  })
  |> filespy.start()
}
