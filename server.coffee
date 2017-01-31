Timer = require 'timer'
Plugin = require 'plugin'
Db = require 'db'
Event = require 'event'
Util = require 'util'
{tr} = require 'i18n'

questions = Util.questions()
userCnt = Plugin.userIds().length
topCnt = Math.min(3, userCnt-1)

exports.getTitle = !-> # prevents title input from showing up when adding the plugin

exports.onInstall = exports.onConfig = (config) !->
    if !Db.shared.get('rounds')
        newRound()

exports.onUpgrade = !->
    log "Updated at " + Plugin.time()

    if !Db.shared.get('rounds')
        newRound()

    ### done
	if curId = Db.shared.get('rounds', 'maxId')
		curRoundTime = Db.shared.get('rounds', curId, 'time')
		roundDuration = Util.getRoundDuration(curRoundTime)
		stillDuration = curRoundTime+roundDuration-Plugin.time()
		if stillDuration <= 0
			newRound()
		else
			Timer.cancel()
			Timer.set stillDuration*1000, 'newRound'
			Timer.set (stillDuration-30*60)*1000, 'reminder'
			Db.shared.set 'next', curRoundTime+roundDuration
	###

exports.onJoin = !->
    if userCnt >= 3 and !Db.shared.get('rounds', 'maxId')
        newRound()

exports.client_newRound = exports.newRound = newRound = !->
    return if userCnt < 3 or +Db.shared.get('next') is -1
        # -1 is for my plugins and master happenings
    maxId = Db.shared.get('rounds', 'maxId') || 0

    # close previous round
    prevHadWinner = false
    if maxId and !Db.shared.get('rounds', maxId, 'results')
        prevHadWinner = close maxId

    log 'maxId, prevHadWinner', maxId, prevHadWinner

    # find questions already used, select new one:
    used = []
    for i in [1..maxId]
        qid = Db.shared.get 'rounds', i, 'qid'
        used.push +qid

    available = []
    for q, nr in questions
        if +nr not in used
            available.push +nr

    if available.length
        maxId = maxId + 1
        Db.shared.set 'rounds', 'maxId', maxId

        rndPos = Math.floor(Math.random()*available.length)
        newQid = available[rndPos]

        time = 0|(Date.now()*.001)
        Db.shared.set 'rounds', maxId,
            qid: newQid
            question: questions[newQid][0]
            time: time

        roundDuration = Util.getRoundDuration(time)

        Timer.cancel()
        if roundDuration > 3600
            Timer.set roundDuration*1000, 'newRound'
            Timer.set (roundDuration-30*60)*1000, 'reminder'
            Db.shared.set 'next', time+roundDuration

        if !prevHadWinner
            Event.create
                unit: 'round'
                text: "New ranking round: " + Util.qToQuestion(questions[newQid][0])

exports.reminder = !->
    roundId = Db.shared.get('rounds', 'maxId')
    remind = []
    for userId in Plugin.userIds()
        rankings = Db.personal(userId).get 'rankings', roundId
        if !rankings or !rankings[1]
            remind.push userId

    if remind.length
        qId = Db.shared.get 'rounds', roundId, 'qid'
        Event.create
            for: remind
            unit: 'remind'
            text: Util.qToQuestion(questions[qId][0]) + ' ' + tr("30 minutes left to vote!")


close = (roundId = false) !->
    roundId = roundId || Db.shared.get('rounds', 'maxId')
    log 'closing round', roundId

    # calculate results here using personal data (we only take into account current users)
    scores = {}
    voteCnt = 0
    for userId in Plugin.userIds()
        # make sure everyone is represented
        if !scores[userId]?
            scores[userId] = 0

        rankings = Db.personal(userId).get 'rankings', roundId
        if rankings and rankings[1] and rankings[2]
            scores[rankings[1]] = (scores[rankings[1]]||0) + 3 # this max-score is used below as well!
            scores[rankings[2]] = (scores[rankings[2]]||0) + 2
            if rankings[3]
                scores[rankings[3]] = (scores[rankings[3]]||0) + 1
            voteCnt++

    Db.shared.set 'rounds', roundId, 'votes', voteCnt

    if !voteCnt
        log 'no scores', roundId
        Db.shared.set 'rounds', roundId, 'results', false
        return false

    results = []
    for userId, score of scores when voteCnt>0
        results.push([userId, score, score + (Math.random() * 0.5 - 0.25)])
            # some jitter is added to randomize same-score order

    results.sort (a, b) -> b[2] - a[2]
    resultsObj = { 1: 0, 2: 0, 3: 0 }
    percsObj = { 1: 0, 2: 0, 3: 0 }

    log 'sorted results', JSON.stringify(results)

    # top 3 (also works for top 2)
    for value, pos in results
        userId = +value[0]
        score = value[1]
        resultsObj[pos+1] = userId # one-based
        percsObj[pos+1] = Math.round(score / (voteCnt * 3) * 100)
            # this uses the max-score of 3 (see above as well) to calculate
            # the percentage of max possible points received
        break if pos is 2 # pos 0, 1, 2

    Db.shared.set 'rounds', roundId, 'percs', percsObj

    # now divide remaining 4...x over bucket 4 and 5
    resultsObj[4] = []
    resultsObj[5] = []

    if results.length is 4
        resultsObj[4].push(+results[3][0])
    else if results.length > 4
        resultCnt = results.length
        middle = 3+(resultCnt-4)/2
        best = {diff: resultCnt, pos: if results[3][1] then results.length else 3}
        for pos in [4...resultCnt] when results[pos-1][1] > results[pos][1]
            # the score is lower than the prev result
            if best.diff > (diff = Math.abs(pos-middle))
                # it's closer to the middle then the former best result
                best = {diff, pos}

        #resultsObj[4] = results.slice 3, best.pos-3
        #resultsObj[5] = results.slice best.pos

        #log 'best pos', best.pos
        for i in [3...best.pos] when 3<best.pos
            resultsObj[4].push(+results[i][0])
        for i in [best.pos...results.length] when best.pos<results.length
            resultsObj[5].push(+results[i][0])

    log 'resultsObj', JSON.stringify(resultsObj)
    Db.shared.set 'rounds', roundId, 'results', resultsObj

    # calculate personal score
    for userId in Plugin.userIds()
        self = Db.personal(userId).get 'rankings', roundId, 'self'
        curScore = Db.shared.get 'competition', userId

        if !curScore?
            # new user, initialize on 2 points per round score
            curScore = (roundId-1) * 2

        score = 0
        if self
            # participating user
            score = 2
            rank = 0
            for i in [1..5]
                rank = i if +userId is resultsObj[i]

            if rank
                if rank in [1..3]
                    if results[self - 1][1] is results[rank - 1][1]
                        log Plugin.userName(userId) + ': Position ' + rank + ' has the same score as guessed position ' + self + '. ' + results[self - 1][1] + '==' + results[rank - 1][1]
                        diff = 0

                if not diff?
                    log Plugin.userName(userId) + ': diff not yet defined, so calculating now'
                    diff = Math.min(3, Math.abs(rank - self))

                scoring = Util.scoring()
                score = scoring[diff]
                log Plugin.userName(userId) + ': Scored ' + score + ' points'

        Db.shared.set 'competition', userId, curScore + score

    if results.length
        qid = Db.shared.get('rounds', roundId, 'qid')
        Event.create
            unit: 'round'
            text: Plugin.userName(resultsObj[1]) + ' ' + questions[qid][0] + '!'
        return true
    return false

exports.client_rankSelf = (roundId, self) !->
    self = +self
    return if Db.shared.get('rounds', roundId, 'results') or self not in [1..5]
        # round no longer active

    Db.personal(Plugin.userId()).set 'rankings', roundId, 'self', self

exports.client_rankTop = (roundId, values) !->
    return if Db.shared.get('rounds', roundId, 'results') or !values[1] or !values[2] or (topCnt isnt 2 and !values[3])
        # round no longer active

    if values is 'remove'
        Db.personal(Plugin.userId()).remove 'rankings', roundId
    else
        resObj =
            1: +values[1]
            2: +values[2]
            3: +values[3]
        Db.personal(Plugin.userId()).merge 'rankings', roundId, resObj

exports.client_addQuestion = (question) !->
    pos = Db.shared.incr 'questionsLength'
    Db.shared.set 'questions', pos, question

exports.client_editQuestion = (question, pos) !->
    Db.shared.set 'questions', pos, question
