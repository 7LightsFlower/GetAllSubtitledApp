cd /home/sscherrer/GetAllSubtitledApp

# 1. Stop and remove the current containers (volumes stay)
docker compose down

# 2. Rebuild both images from scratch (ignores Docker layer cache)
docker compose build --no-cache backend web

# 3. Start fresh
docker compose up -d

# 4. Confirm
docker compose ps
docker compose logs --tail=20 backend
docker compose logs --tail=20 web
