# Auto deploy Docker Rails with Capistrano

## Setup Rails

Add your `Gemfile`:

```
gem 'figaro'

group :development do
  gem 'capistrano', '~> 3.9'
  gem 'capistrano-figaro'
end
```

We have use `gem "figaro"` for Rails app configuration using ENV and a single YAML file. So, we need `gem 'capistrano-figaro'` for deploy with `capistrano`. You can read more at: [Figaro](https://github.com/laserlemon/figaro).

With this app, you can use mysql or postgresql. At here, I use mysql so I adding my Gemfile:

```
gem 'mysql2', '>= 0.3.18', '< 0.5'
```

Then, we need modify `config/database.yml`:

```yaml
default: &default
  adapter: mysql2
  encoding: utf8
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  min_messages: log


development:
  <<: *default

test:
  <<: *default
  database: myapp_<%= Rails.env %>

production:
  <<: *default
  min_messages: notice

```

Btw, I have been using background processing for my app with [Sidekiq](https://github.com/mperham/sidekiq). I adding Gemfile:

```
gem 'sidekiq'
gem 'sidekiq-scheduler'
```

[sidekiq-scheduler](https://github.com/moove-it/sidekiq-scheduler)  is an extension to Sidekiq that pushes jobs in a scheduled way, mimicking cron utility.

Then, config sidekiq. Create `config/initializers/sidekiq.rb`:

```ruby
require 'sidekiq/scheduler'

redis_setting = {
  url: ENV['REDIS_URL']
}

Sidekiq.configure_server do |config|
  config.redis = redis_setting
  # config.server_middleware do |chain|
  #   chain.add Sidekiq::Middleware::Server::RetryJobs, max_retries: 0
  # end
  config.on(:startup) do
    Sidekiq.schedule = YAML.load_file(File.expand_path("../../../config/scheduler.yml", __FILE__))
    Sidekiq::Scheduler.reload_schedule!
  end
end

Sidekiq.configure_client do |config|
  config.redis = redis_setting
end

```

## Setup Docker

Create `Dockerfile`:

```bash
FROM ruby:2.3-alpine

MAINTAINER YOUR-NAME <your-email>

RUN apk add --no-cache \
  alpine-sdk \
  tzdata \
  nodejs \
  mariadb-dev \
  && rm -rf /var/cache/apk/*

RUN npm -v
RUN npm install -g yarn
RUN echo "gem: --no-rdoc --no-ri" >> ~/.gemrc
RUN gem install bundler

ENV APP_ROOT /opt/app

WORKDIR $APP_ROOT

COPY Gemfile* $APP_ROOT/
RUN bundle install -j4

ARG RAILS_ENV
ENV RAILS_ENV ${RAILS_ENV:-production}
COPY . $APP_ROOT

# Assets precompile
RUN if [ $RAILS_ENV = 'production' ]; then bundle exec rake assets:precompile --trace; fi
# Expose assets for web container
VOLUME $APP_ROOT/public
```

Create `development-entrypoint`:

```bash
#! /bin/bash
set -e

: ${APP_PATH:="/usr/src/app"}
: ${APP_TEMP_PATH:="$APP_PATH/tmp"}
: ${APP_SETUP_LOCK:="$APP_TEMP_PATH/setup.lock"}
: ${APP_SETUP_WAIT:="5"}

# 1: Define the functions lock and unlock our app containers setup
# processes:
function lock_setup { mkdir -p $APP_TEMP_PATH && touch $APP_SETUP_LOCK; }
function unlock_setup { rm -rf $APP_SETUP_LOCK; }
function wait_setup { echo "Waiting for app setup to finish..."; sleep $APP_SETUP_WAIT; }

# 2: 'Unlock' the setup process if the script exits prematurely:
trap unlock_setup HUP INT QUIT KILL TERM EXIT

# 3: Specify a default command, in case it wasn't issued:
if [ -z "$1" ]; then set -- rails server -p 3000 -b 0.0.0.0 "$@"; fi

# 4: Run the checks only if the app code is going to be executed:
if [[ "$1" = "rails" || "$1" = "sidekiq" ]]
then
  # 5: Wait until the setup 'lock' file no longer exists:
  while [ -f $APP_SETUP_LOCK ]; do wait_setup; done

  # 6: 'Lock' the setup process, to prevent a race condition when the
  # project's app containers will try to install gems and setup the
  # database concurrently:
  lock_setup

  # 7: Check if the database exists, or setup the database if it doesn't,
  # as it is the case when the project runs for the first time.
  #
  # We'll use a custom script `check_db` (inside our app's `bin` folder),
  # instead of running `rails db:version` to avoid loading the entire rails
  # app for this simple check:
  rails db:version || setup

  # 8: 'Unlock' the setup process:
  unlock_setup

  # 9: If the command to execute is 'rails server', then we must remove any
  # pid file present. Suddenly killing and removing app containers might leave
  # this file, and prevent rails from starting-up if present:
  if [[ "$2" = "s" || "$2" = "server" ]]; then rm -rf /usr/src/app/tmp/pids/server.pid; fi
fi

# 10: Execute the given or default command:
exec "$@"
```

Create `docker-compose.yml`:

```yaml
version: '2'
services:
  app:
    image: myapp:latest
    build:
      context: .
      args:
        RAILS_ENV: development
    volumes:
      - public_data:/opt/app/public
      - ./log:/opt/app/log
      - assets:/usr/app/${APP_NAME}/public/assets
    environment:
      SECRET_KEY_BASE: '1bc3093b3635bfc89adceadb54b97666db1707affcc86f1a4c810e16622c65a31c0ad6c9f497fe124f01b45a4d0595183e7cbffd641e8d43d8a07ec0345f6062'
      DATABASE_URL: 'mysql2://mayapp:myapp@db/myapp_development'
      REDIS_URL:    'redis://redis:6379'
    links:
      - db
      - redis
    command: bundle exec rails s
  db:
    image: mysql:5.6
    environment:
      MYSQL_ROOT_PASSWORD: myapp
      MYSQL_DATABASE: myapp_development
      MYSQL_USER: mayapp
      MYSQL_PASSWORD: myapp
    volumes:
      - /var/lib/mysql
  web:
    build: containers/nginx
    volumes:
      - ./log:/opt/app/log
      - ./tmp:/opt/app/tmp
      - public_data:/opt/app/public
    ports:
      - "80:80"
    links:
      - app
  worker:
    build:
      context: .
      args:
        RAILS_ENV: development
    volumes:
      - /data
    environment:
      RAILS_ENV: development
      DATABASE_URL: 'mysql2://myapp:myapp@db/myapp_development'
      REDIS_URL:    'redis://redis:6379'
    links:
      - db
      - redis
    command: [bundle, exec, sidekiq, -C, containers/app/sidekiq.yml]
  redis:
    image: redis:3.0
    volumes:
      - /data
    ports:
      - "6379"
volumes:
  assets:
    external: false
  public_data:
    external:
      name: public_data_volume
  data:
    external:
      name: data_volume
```

Create `containers/app/sidekiq.yml`:

```yaml
development:
  :verbose: true
  :concurrency: 4
production:
  :logfile: ./log/sidekiq.log
  :concurrency: 10
:queues:
  - default
  - mailers
```


Create `containers/nginx/Dockerfile`:

```bash
FROM nginx:stable-alpine

MAINTAINER YOUR-NAME <your-email>

COPY nginx.conf /etc/nginx/conf.d/default.conf
```

Create `containers/nginx/nginx.conf`:

```bash
upstream app {
  server app:3000;
}

server {
  listen 80 default_server;
  listen 443 default_server;
  server_name _;
  keepalive_timeout 5;
  root /opt/app/public;
  access_log /opt/app/log/nginx.access.log;
  error_log /opt/app/log/nginx.error.log info;

  location / {
    proxy_pass http://app;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Host $http_host;
  }
}
```

### Starting Rails with Docker

```bash
cd your-app

docker-compose build
```

Setup database:

```bash
docker-compose run app rails db:create db:migrate
```

Starting your app:

```bash
docker-compose up
```

or

```bash
docker-compose up -d
```

Go to: **localhost:80**

View docker working:

```bash
docker ps
```

Stop:

```bash
docker-compose stop
```

Rebuild your app:

```
docker-compose build app
```

But, currently your app cannot run with Docker. We need install Docker on your server.

## Setup server

In this article, I use AWS EC2 with Ubuntu already installed for my server.

### Connect your AWS Instance via Terminal

First, we need install git.

```
sudo apt-get update && sudo apt-get -y upgrade
sudo apt-get install git
```

Then, 

```
ssh-keygen -t rsa -C "your-github-email"
cat ~/.ssh/github.pub
```

Copy and add new ssh key at github setting.
Test connection:

```
ssh -T git@github.com
```

### Install Docker on Ubuntu

Remember, keep connect your AWS Instance via Terminal.

Install using Ubuntu-managed packages:

```
sudo apt-get install docker.io
```

To make the shell easier to use, we need to create a symlink since `/usr/local/bin` is for normal user programs not managed by the distribution package manager. The following command overwrites the link (`/usr/local/bin/docker`):

```
sudo ln -sf /usr/bin/docker.io /usr/local/bin/docker
```

To enable tab-completion of Docker commands in BASH, either restart BASH or:

```
source /etc/bash_completion.d/docker.io
```

or

```
source /etc/bash_completion.d/docker
```

To check if Docker is running:

```
$ ps aux | grep docker
```

If we want to run docker as root user, we should add a user (in my case, 'k') to the docker group:

```
sudo usermod -aG docker k
```

### Create user deploy

Add new user:

```
sudo adduser USERNAME
```

If user has been exist:

```
sudo passwd USERNAME
```

Enable password authentication by editing `/etc/ssh/sshd_config`: change `PasswordAuthentication no` to `PasswordAuthentication yes`.

Use command as **root** user. By default, a new user is only in their own group, which is created at the time of account creation, and shares a name with the user. In order to add the user to a new group, we can use the usermod command:

```
usermod -aG sudo USERNAME
```

Open:

```
sudo vi /etc/sudoers
```

and add:

```
USERNAME ALL=(ALL:ALL) ALL
```

then restart:

```
sudo /etc/init.d/ssh restart
```

Now, you can connect via Terminal with user and password:

```
ssh USERNAME@ec2-________.compute-1.amazonaws.com
USERNAME@ec2-________.compute-1.amazonaws.com's password:
```

## Setup Capistrano

Read more at [here](https://github.com/capistrano/capistrano#quick-start).

Add `Capfile`:

```
require 'capistrano/figaro'
```


Modify `config/deploy.rb`:

```ruby
# config valid only for current version of Capistrano
lock "3.9.0"

set :application, ENV['APP_NAME']

set :repo_url, ENV['REPO_URL']

# Default branch is :master
# ask :branch, `git rev-parse --abbrev-ref HEAD`.chomp

# Default deploy_to directory is /var/www/my_app_name
# set :deploy_to, "/var/www/my_app_name"
set :deploy_to, -> { "/var/www/#{fetch(:application)}_#{fetch(:stage)}" }

# Default value for :format is :airbrussh.
# set :format, :airbrussh

# You can configure the Airbrussh format using :format_options.
# These are the defaults.
# set :format_options, command_output: true, log_file: "log/capistrano.log", color: :auto, truncate: :auto

# Default value for :pty is false
# set :pty, true

# Default value for :linked_files is []
# append :linked_files, "config/database.yml", "config/secrets.yml"

# Default value for linked_dirs is []
# append :linked_dirs, "log", "tmp/pids", "tmp/cache", "tmp/sockets", "public/system"

# Default value for default_env is {}
# set :default_env, { path: "/opt/ruby/bin:$PATH" }

# Default value for local_user is ENV['USER']
# set :local_user, -> { `git config user.name`.chomp }

# Default value for keep_releases is 5
set :keep_releases, 5

set :ssh_options, {
 forward_agent: true
}

server ENV['SERVER_IP'], user: ENV['DEPLOY_USER'], roles: %w(app web db), :primary => true
```

Adding at `deploy/production.rb`:

```ruby
set :branch, 'master'
```

Create `config/application.yml`:

```yaml
APP_NAME: myapp
REPO_URL: git@github.com:your-git-path.git
SERVER_IP: your-server-ip
SERVER_DOMAIN: your-domain
DEPLOY_USER: your-user-server
```

### Testing:

```
cap production deploy:check
```

It work fine! 

## Deploy step by step with Capistrano

Deploy new code from master branch:

```
cap production deploy
```


When it has been successfully, connect server via terminal. 

```
cd /var/www/mayapp_production/current/
```

- `/var/www/` has been config at line:

```
set :deploy_to, -> { "/var/www/#{fetch(:application)}_#{fetch(:stage)}" }
```

- `mayapp` is **APP_NAME**.
- `production` : we have been use `cap production deploy`.
- `current` is folder contains latest source from master branch.

Now, we can using Docker:

```
docker-compose build
docker-compose up -d
```

If first time deploy, we need set up database:

```
docker-compose run app rails db:create db:migrate db:seed
```

Or, we have new changes for database:

```
docker-compose run app rails db:migrate
```

In case, we have been changed for app, we must rebuild.

```
docker-compose build app
```

This app will run at `your-server-ip` with port `80`.

## Add your domain with instance

We will use Cloudflare.

After you register and login your account, add site with your domain, config DNS. We use public ip of instance `52.90.195.71` :

## Config Security Group

Your Security Group of Instance need config same as :

