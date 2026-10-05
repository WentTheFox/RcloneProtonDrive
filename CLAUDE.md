# TODO

* Failing to sync a file due to too strict permissions (the SYSTEM account hosting the service not being allowed to access a file) the sync service call was failing with 500 internal server errors with no details about the issue beyond `rcd.log` containing a few instances of

    > \<TIMESTAMP> : ERROR : \<FILE PATH REDACTED>: Failed to copy: failed to open source object: Access is denied.
 
  It's not clear either from the tray icon or the notification message what went wrong, the 500 error response details got buried in the service logs and contained no useful information. Even after extending the logging the output shows only this:

    > \<TIMESTAMP> bisync sync FAILED: The remote server returned an error: (500) Internal Server Error. {
    >	"error": "bisync aborted",
    >	"input": <REDACTED>,
    >	"path": "sync/bisync",
    >	"status": 500
    > }
    > 
    > \<TIMESTAMP> Response Status: InternalServerError
    > 
    > \<TIMESTAMP> Response Body:

  with the body being empty. We need to improve the UX for wrong file permissions causing the sync process to run into a 500 error.
