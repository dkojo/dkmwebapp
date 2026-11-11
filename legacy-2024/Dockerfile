#RUN ./create-package.sh
FROM openjdk:11
VOLUME /tmp
ADD target/itgenuine-0.0.1-SNAPSHOT.jar itgenuine-0.0.1-SNAPSHOT.jar
EXPOSE 8085
ENTRYPOINT ["java","-jar","itgenuine-0.0.1-SNAPSHOT.jar", "-Dspring.profiles.active=prod"]