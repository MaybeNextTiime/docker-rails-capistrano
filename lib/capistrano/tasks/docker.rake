namespace :docker do

  desc "Export ENV"
  task :export_env  do
    on roles(:app) do
      execute "cd #{current_path} && export DATABASE_URL=#{ENV['DATABASE_URL']}"
    end
  end

  desc "docker-compose build"
  task :build_all do
    on roles(:app) do
      execute "cd #{current_path} && docker-compose build"
    end
  end

  desc "docker-compose build app"
  task :build_app do
    on roles(:app) do
      execute "cd #{current_path} && docker-compose build app"
    end
  end

  desc "Docker create volums"
  task :create_volums do
    on roles(:app) do
      execute "docker volume create --name=data_volume && docker volume create --name=public_data_volume"
    end
  end

  desc "docker-compose up -d "
  task :up do
    on roles(:app) do
      execute "cd #{current_path} && docker-compose up -d"
    end
  end

  desc "docker-compose stop"
  task :stop do
    on roles(:app) do
      execute "cd #{current_path} && docker-compose stop"
    end
  end

  desc "Remove networks"
  task :remove_networks do
    on roles(:app) do
      system "cd #{current_path} && docker network ls | grep \"bridge\""
      system "cd #{current_path} && docker network rm $(docker network ls | grep \"bridge\" | awk '/ / { print $1 }')"
    end
  end

  desc "Setup Database"
  task :setup_db do
    on roles(:app) do
      execute "cd #{current_path} && docker-compose run app rails db:create db:migrate db:seed"
    end
  end

  desc "Run db:migrate"
  task :db_migration do
    on roles(:app) do
      execute "cd #{current_path} && docker-compose run app rails db:migrate db:seed"
    end
  end

  desc "Run assets:precompile"
  task :assets do
    on roles(:app) do
      execute "cd #{current_path} && docker-compose run app rake assets:clean"
      execute "cd #{current_path} && docker-compose run app rake assets:precompile"
    end
  end

  desc "Reset Database"
  task :reset_db do
    on roles(:app) do
      execute "cd #{current_path} && docker-compose run app rails db:drop db:create db:migrate db:seed"
    end
  end

end
