FROM ruby:2.2.8
RUN apt-get update
RUN echo 'mysql-server mysql-server/root_password password password' | debconf-set-selections
RUN echo 'mysql-server mysql-server/root_password_again password password' | debconf-set-selections
RUN apt-get -y install mysql-server
ENV APP_DIR=/precision-fda
WORKDIR $APP_DIR
RUN mkdir -p $APP_DIR
COPY Gemfile Gemfile.lock $APP_DIR/
RUN bundle install
COPY . $APP_DIR
CMD $APP_DIR/docker-test-entrypoint.sh