//shared mongo bootstrap. All db/user/pass come from env (Job sets MONGO_DATABASE per env).
function waitForMongo(maxAttempts, delaySec) {
  maxAttempts = maxAttempts || 30;
  delaySec = delaySec || 2;
  for (var i = 1; i <= maxAttempts; i++) {
    try {
      db.adminCommand({ ping: 1 });
      print("Mongo ready after " + i + " attempt(s)");
      return;
    } catch (e) {
      if (i === maxAttempts) throw e;
      print("Waiting for mongo (" + i + "/" + maxAttempts + ")...");
      sleep(delaySec * 1000);
    }
  }
}
try {
  const dbName = process.env.MONGO_DATABASE;
  const appUser = process.env.MONGO_APP_USERNAME;
  const appPassword = process.env.MONGO_APP_PASSWORD;
  if (!dbName || !appUser || !appPassword) {
    print("ERROR: MONGO_DATABASE, MONGO_APP_USERNAME, MONGO_APP_PASSWORD must be set");
    quit(1);
  }
  waitForMongo();
  const adminDb = db.getSiblingDB("admin");
  const existing = adminDb.getUser(appUser);
  if (existing) {
    adminDb.updateUser(appUser, {
      pwd: appPassword,
      roles: [{ role: "readWrite", db: dbName }]
    });
    print("Updated existing app_user: " + appUser);
  } else {
    adminDb.createUser({
      user: appUser,
      pwd: appPassword,
      roles: [{ role: "readWrite", db: dbName }]
    });
    print("Created app_user: " + appUser);
  }
  quit(0);
} catch (err) {
  print("ERROR: " + err.message);
  quit(1);
}
