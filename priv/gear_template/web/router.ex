defmodule <%= gear_name_camel %>.Router do
  use Antikythera.Router

  get "/hello", Hello, :hello
end
