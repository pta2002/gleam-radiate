import filespy
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import shellout

/// Phantom type to indicate no directories are added
pub type NoDirectories

/// Phantom type to indicate directories have been added
pub type HasDirectories

/// Phantom type to indicate builder has no initializer
pub type NoInitializer

/// Phantom type to indicate builder has initializer
pub type HasInitializer

/// Phantom type to indicate builder has no callback
pub type NoCallback

/// Phantom type to indicate builder has callback
pub type HasCallback

/// Phantom type to indicate builder has before callback
pub type HasBeforeCallback

/// Phantom type to indicate builder has no before callback
pub type NoBeforeCallback

/// Opaque builder type for reloader. Create with `new`.
pub opaque type Builder(
  state,
  has_dirs,
  has_initializer,
  has_callback,
  has_before_callback,
) {
  Builder(
    dirs: List(String),
    callback: fn(state, String) -> state,
    initializer: Option(fn() -> state),
    before_callback: Option(fn(state, String) -> state),
  )
}

/// Construct a new builder
pub fn new() -> Builder(
  Nil,
  NoDirectories,
  NoInitializer,
  NoCallback,
  NoBeforeCallback,
) {
  fn(state, path) {
    io.println("Change in " <> path <> ", reloading.")
    state
  }
  |> Builder(dirs: [], callback: _, initializer: None, before_callback: None)
}

/// Add a directory to watch. The path can be relative or absolute.
/// macOS users: always use `"."` or an absolute path, otherwise it won't work
/// properly!
pub fn add_dir(
  builder: Builder(
    state,
    has_dirs,
    has_initializer,
    has_callback,
    has_before_callback,
  ),
  dir: String,
) -> Builder(
  state,
  HasDirectories,
  has_initializer,
  has_callback,
  has_before_callback,
) {
  Builder(
    dirs: [dir, ..builder.dirs],
    callback: builder.callback,
    initializer: builder.initializer,
    before_callback: builder.before_callback,
  )
}

/// Add a callback to be run after reload
pub fn on_reload(
  builder: Builder(
    state,
    has_dirs,
    has_initializer,
    NoCallback,
    has_before_callback,
  ),
  callback: fn(state, String) -> state,
) -> Builder(state, has_dirs, has_initializer, HasCallback, has_before_callback) {
  Builder(
    dirs: builder.dirs,
    callback: callback,
    initializer: builder.initializer,
    before_callback: builder.before_callback,
  )
}

//add a callback to handle a process before reloading modules
pub fn before_reload(
  builder: Builder(
    state,
    has_dirs,
    has_initializer,
    NoCallback,
    has_before_callback,
  ),
  before_callback: fn(state, String) -> state,
) -> Builder(state, has_dirs, has_initializer, has_callback, HasBeforeCallback) {
  Builder(
    dirs: builder.dirs,
    callback: builder.callback,
    initializer: builder.initializer,
    before_callback: Some(before_callback),
  )
}

/// Add an initializer
///
/// This will be run in the file watcher process, so it can be useful to, for
/// example, add state to an actor
pub fn set_initializer(
  builder: Builder(
    state,
    has_dirs,
    NoInitializer,
    has_callback,
    has_before_callback,
  ),
  initializer: fn() -> state,
) -> Builder(state, has_dirs, HasInitializer, has_callback, has_before_callback) {
  Builder(
    dirs: builder.dirs,
    callback: builder.callback,
    initializer: Some(initializer),
    before_callback: builder.before_callback,
  )
}

type Module

type What

@external(erlang, "code", "modified_modules")
fn modified_modules() -> List(Module)

@external(erlang, "code", "purge")
fn purge(module: Module) -> Bool

@external(erlang, "code", "atomic_load")
fn atomic_load(modules: List(Module)) -> Result(Nil, List(#(Module, What)))

/// Start reloader, if no state has been set
pub fn start(
  builder: Builder(
    Nil,
    HasDirectories,
    NoInitializer,
    has_callback,
    has_before_callback,
  ),
) {
  builder
  |> set_initializer(fn() { Nil })
  |> start_state()
}

//handler for reloading file changes
fn execute_reload(
  builder: Builder(
    state,
    HasDirectories,
    HasInitializer,
    has_callback,
    has_before_callback,
  ),
  state,
  path,
) -> state {
  let build_result = shellout.command(["build"], run: "gleam", in: ".", opt: [])

  case build_result {
    Ok(_output) -> {
      let mods = modified_modules()
      list.each(mods, purge)
      let _ = atomic_load(mods)
      builder.callback(state, path)
    }

    Error(#(_status, message)) -> {
      message
      |> io.print_error

      state
    }
  }
}

/// Start reloader, ensuring that a state has been set
pub fn start_state(
  builder: Builder(
    state,
    HasDirectories,
    HasInitializer,
    has_callback,
    has_before_callback,
  ),
) {
  filespy.new()
  |> filespy.set_initializer(fn() {
    let assert Some(init) = builder.initializer
    init()
  })
  |> filespy.add_dirs(builder.dirs)
  |> filespy.set_actor_handler(fn(msg, state) {
    case msg {
      filespy.Custom(_) -> actor.continue(state)
      filespy.Change(path, events) -> {
        // todo fold over state... gah!
        list.fold(events, state, fn(state, event) {
          case event {
            filespy.Closed | filespy.Modified -> {
              // Check if path ends in '.gleam'
              case string.ends_with(path, ".gleam") {
                True -> {
                  //check if there is a before callback
                  case builder.before_callback {
                    Some(before) -> {
                      before(state, path)
                      execute_reload(builder, state, path)
                    }
                    _ -> {
                      execute_reload(builder, state, path)
                    }
                  }
                }

                _ -> state
              }
            }
            _ -> state
          }
        })
        |> actor.continue
      }
    }
  })
  |> filespy.start()
}
