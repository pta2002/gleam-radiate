import gleam/erlang/process
import gleam/io
import message
import radiate

pub fn main() {
  let _ =
    radiate.new()
    |> radiate.add_dir(".")
    |> radiate.start()

  let timer_subject = process.new_subject()

  print_every_second(timer_subject)
}

fn print_every_second(subject: process.Subject(Nil)) {
  process.send_after(subject, 1000, Nil)

  let _ = process.receive(subject, 1500)
  io.println(message.get_message())

  print_every_second(subject)
}
