defmodule WtDemoWeb.Router do
  use WtDemoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WtDemoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", WtDemoWeb do
    pipe_through :browser

    live "/", CompareLive
    live "/demo", DemoLive
    get "/hold", HoldController, :hold
  end

  # Other scopes may use custom stacks.
  # scope "/api", WtDemoWeb do
  #   pipe_through :api
  # end
end
