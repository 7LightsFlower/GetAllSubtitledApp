import os, pickle
STATE = "server_state.pkl"          # adjust if needed
with open(STATE, "rb") as f:
    st = pickle.load(f)

for v in st.get("videos", []):
    t = v.get("thumbnail_url") or ""
    if " " in t:
        v["thumbnail_url"] = "/thumbnails/" + os.path.basename(t)
        print("fixed:", v["thumbnail_url"])

with open(STATE, "wb") as f:
    pickle.dump(st, f)