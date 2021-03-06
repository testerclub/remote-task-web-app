"use strict"

dbmodule = require("./module")
logger = require("./logger")

CreateMode = require('node-zookeeper-client').CreateMode
request = require("request")
url = require("url")
_ = require("underscore")
Backbone = require ("backbone")

start = ->
  data = dbmodule.data()
  db = dbmodule.db()
  redis = dbmodule.redis()

  devices = data.models.devices
  live_jobs = data.models.live_jobs
  zk_jobs = data.models.jobs
  events = _.extend {}, Backbone.Events

  schedule_count = 0
  schedule = ->
    # urgly. We want not to schedule for every "remove" event, so add 5 seconds delay.
    schedule_count += 1
    setTimeout arrange, 5000 if schedule_count is 1

  arrange = ->
    schedule_count = 0
    live_jobs.forEach (job) -> logger.debug "Job #{job.id}: status=#{job.get('status')}, locked=#{job.get('locked')}"
    devices.forEach (device) -> logger.debug "Device #{device.id}: idle=#{device.get('idle')}, locked=#{device.get('locked')}"
    [10..1].forEach (priority) -> live_jobs.filter((job) -> job.get("priority") is priority and job.get("status") is "new" and not job.get("locked")).forEach (job) ->
      if dbmodule.methods.has_exclusive(job.toJSON()) or dbmodule.methods.has_dependency(job.toJSON())
        logger.debug "Job #{job.id} has #{job.get('r_type')} on #{JSON.stringify(job.get("r_job_nos"))}."
      else
        filter = job.get("device_filter") or {}
        device = devices.find (dev) ->
          dev.get("idle") and not dev.get("locked") and dbmodule.methods.match(filter, dev)
        assign_task(device, job) if device?

  assign_task = (device, job) ->
    logger.info "Assigning job #{job.id} to device #{device.id}."
    job.set {locked: true, assigned_device: device.id}, {silent: true}
    device.set {locked: true}, {silent: true}
    url_str = url.format(
      protocol: "http"
      hostname: device.get("workstation").ip
      port: device.get("workstation").port
      pathname: "#{device.get('workstation').path}/0/jobs/#{job.id}"
    )
    body =
      env: job.get("environ")
      repo:
        url: job.get("repo_url")
    body.repo.branch = job.get("repo_branch") if job.has("repo_branch")
    body.repo.username = job.get("repo_username") if job.has("repo_username")
    body.repo.password = job.get("repo_passowrd") if job.has("repo_passowrd")
    body.env["ANDROID_SERIAL"] = device.get("serial")
    body.env["TASK_ID"] = job.get("task_id")
    body.env["JOB_NO"] = job.get("no")
    request.post {url: url_str, json: body}, (err, res, body) ->
      if err? or res.statusCode isnt 200
        logger.error "Error when assigning job #{job.id} to device #{device.id}, response is #{body}"
        job.unset "locked", silent: true # triggered by device change next step, so silent for job change.
        job.unset "assigned_device", silent: true
        device.unset "locked"
      else
        db.models.device.find {workstation_mac: device.get("workstation").mac, serial: device.get("serial")}, (err, devices) ->
          events.trigger("update:job", {
            find:
              id: job.id
              status: "new"
            update:
              device: devices[0]
              status: "started"
            callback: (err) ->
              events.trigger "retrive:jobinfo",
                job_id: job.id
                workstation: device.get("workstation")
          }) if devices?.length > 0

  finish_job = (event) ->
    id = event.id
    ws = event.get("workstation")
    logger.info "Job #{id} finished."

    events.trigger("update:job",
      find:{id: id, status: "started"}
      update: {status: "finished"}
      callback: (err) ->
        return logger.error("Error during saving job as finished: #{err}") if err?

        events.trigger "retrive:jobinfo",
          job_id: id
          workstation: ws
    )

  devices.on "add", (device) ->
    db.models.device.create {workstation_mac: device.get("workstation").mac, serial: device.get("serial")}, (err, device) ->
      return if err?
      db.models.tag.find (err, tags) ->
        return if err?
        default_tags = ["system:role:admin"]
        device.addTags _.filter(tags, (t) -> t.tag in default_tags), (err) ->
          return if err?
          redis.publish "db.device.tag", JSON.stringify(method: "add", device: device.id, tags: default_tags)
  devices.on "change add", (device) -> # when there is an unlocked and idle device, we should schedule.
    schedule() if device.get("idle") and not device.get("locked")

  live_jobs.on "change add", (job) -> # when there is an unlocked and new job, we should schedule.
    schedule() if job.get("status") is "new" and not job.get("locked")
  live_jobs.on "remove", (job) ->
    devices.get(job.get("assigned_device"))?.unset("locked", {silent: true}) if job.has("assigned_device")
    schedule()  # when a running removed, some dependent/exclusive jobs need to be scheduled.
  live_jobs.on "change:status", (job) -> # unset locked in case of job status change due to started or restart
    if job.get("status") is "new"
      if job.has("assigned_device")
        devices.get(job.get("assigned_device"))?.unset("locked")
        job.unset("assigned_device", silent: true)
      job.unset("locked")

  zk_jobs.on "remove", finish_job

  zk_jobs.on "add", (job) ->
    # Due to async issue, job process may be running but the job status in db is not started.
    # So we need to kill the untracked job.
    # But unfortunatelly, when the schedular is started, the "add" event may be triggered before
    # the live_jobs is retrieved from db, so we will have to delay some secondes to check if the
    # job is really untracked.
    setTimeout( ->
        if live_jobs.get(job.id)?.get("status") is "started"
          if zk_jobs.filter((j) -> j.id is job.id).length > 1
            # two or more jobs in zk with the same id, so kill this one.
            ws = job.get("workstation")
            url_str = url.format(
              protocol: "http"
              hostname: ws.ip
              port: ws.port
              pathname: "#{ws.path}/0/jobs/#{job.id}/stop"
            )
            request.get url_str, (err, r, b) ->
            logger.warn "Kill redundant job: #{job.id}"
        else if zk_jobs.filter((j) -> j.id is job.id).length is 1
          # the job status in db is not 'started', but it does exist in zk,
          # it may be caused by network disconnect between workstation and zk.
          # so we should change its status to 'started' in db.
          events.trigger 'update:job',
            find:
              id: job.id
              status: ["new", "finished", "cancelled"]
            update:
              status: "started"
      , 10000
    ) unless live_jobs.get(job.id)?.get("status") is "started"

  events.on "update:job", (msg) ->
    logger.debug "Find jobs #{JSON.stringify(msg.find)} and update to #{JSON.stringify(msg.update)}"
    db.models.job.find(msg.find).each((job) ->
      _.each msg.update, (v, p)-> job[p] = v
    ).save (err) ->
      return msg.callback?(err) if err?
      redis.publish "db.job", JSON.stringify({find: msg.find, update: msg.update})
      msg.callback?()

  events.on 'retrive:jobinfo', (msg) ->
    id = msg.job_id
    ws = msg.workstation
    url_str = url.format(
      protocol: "http"
      hostname: ws.ip
      port: ws.port
      pathname: "#{ws.path}/0/jobs/#{id}"
    )
    request.get url_str, (err, r, b) ->
      return logger.error("Error when retrieving job result from workstation: #{err}") if err? or r.statusCode isnt 200
      events.trigger "update:job",
        find:
          id: id
        update:
          exit_code: JSON.parse(b).exit_code
          exec_info: JSON.parse(b)

  setInterval schedule, 60*1000

module.exports = 
  schedule: ->
    data = dbmodule.data()
    data.zk_client.mkdirp "/remote/alive/schedular", (err, path) ->
      data.zk_client.create "/remote/alive/schedular/lock", CreateMode.EPHEMERAL, (err, path) ->
        process.on "SIGINT", ->
          data.zk_client.remove "/remote/alive/schedular/lock", (err) ->
            logger.info "Schedular terminated!"
            process.exit()
        if err
          logger.info "Another schedular may be running."
          logger.info "Please make sure only one schedular is running or try it again later."
          return process.exit(-1)
        start()
