ssh sscherrer@i13entry2.isl.iar.kit.edu

cp -ri /home/cmullov/docker/GetAllSubtitledApp/GetAllSubtitledApp .

cd GetAllSubtitledApp/

git status

git diff

docker build -t getallsubtitled:v0.1 .

docker compose up -d

