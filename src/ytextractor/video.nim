#[
  Created at: 08/09/2021 12:10:05 Monday
  Modified at: 08/14/2021 11:21:29 PM Saturday
]#

##[
  video
  -----

  Parser for "https://www.youtube.com/watch?v=VIDEOID"
]##

{.experimental: "codeReordering".}

from std/times import DateTime, Duration, initDuration, now
from std/json import JsonNode, items, hasKey, `{}`, getStr, getInt, getBool
from std/strformat import fmt
from std/strutils import parseInt, multiReplace, find, strip

import ytextractor/core/core
from ytextractor/channel import channelId

type
  YoutubeVideo* = object of YoutubeVideoPreview
    ## Youtube video object
    status*: ExtractStatus
    id*: YoutubeVideoId
    title*, description*: string
    thumbnails*: seq[UrlAndSize]
    embed*: UrlAndSize
    publishDate*, uploadDate*: DateTime
    length*: Duration
    familyFriendly*, unlisted*, private*, live*: bool
    channel*: YoutubeChannelPreview
    views*: int
    category*: YoutubeVideoCategories
    likes*, dislikes*: int
    keywords*: seq[string]
  YoutubeVideoCategories* {.pure.} = enum
    ## Youtube video categories
    Unknown, FilmAndAnimation, AutosAndVehicles, Music, PetsAndAnimals, Sports,
    TravelAndEvents, Gaming, PeopleAndBlogs, Comedy, Entertainment,
    NewsAndPolitics, HowtoAndStyle, Education, ScienceAndTechnology,
    NonprofitsAndActivism
  YoutubeVideoId* = distinct string
    ## Video Id is a distinct string just for disallow pass any string to parser

proc parseCategory*(str: string): YoutubeVideoCategories =
  ## Parses the category to `YoutubeVideoCategories`
  runnableExamples:
    doAssert parseCategory("People & Blogs") == YoutubeVideoCategories.PeopleAndBlogs
  case str:
  of "Film & Animation": FilmAndAnimation
  of "Autos & Vehicles": AutosAndVehicles
  of "Music": Music
  of "Pets & Animals": PetsAndAnimals
  of "Sports": Sports
  of "Travel & Events": TravelAndEvents
  of "Gaming": Gaming
  of "People & Blogs": PeopleAndBlogs
  of "Comedy": Comedy
  of "Entertainment": Entertainment
  of "News & Politics": NewsAndPolitics
  of "Howto & Style": HowtoAndStyle
  of "Education": Education
  of "Science & Technology": ScienceAndTechnology
  of "Nonprofits & Activism": NonprofitsAndActivism
  else: Unknown

proc `$`*(id: YoutubeVideoId): string =
  ## Convert `YoutubeVideoId` to `string`
  runnableExamples:
    echo $typeof($"Dx4eelwPGaQ".YoutubeVideoId) == "string"
  id.string

proc initYoutubeVideo*(id: YoutubeVideoId): YoutubeVideo =
  ## Initialize a new `YoutubeVideo` instance
  YoutubeVideo(id: id)

proc update*(self: var YoutubeVideo; proxy = ""): bool =
  ## Update all `YoutubeVideo` data
  ## Returns `false` on error.
  ##
  ## .. code-block:: nim
  ##   var vid = initYoutubeVideo("Dx4eelwPGaQ".videoId)
  ##   if not vid.update():
  ##     echo "Error to update: " & $vid.status.error
  ##   echo vid
  result = true

  if not self.id.valid:
    self.status.error = ExtractError.InvalidId
    return false

  let
    jsonData = fetch(fmt"{proxy}https://www.youtube.com/watch?v={self.id}").
      parseYoutubeJson()
    microformat = jsonData.ytInitialPlayerResponse{"microformat", "playerMicroformatRenderer"}
    videoDetails = jsonData.ytInitialPlayerResponse{"videoDetails"}
    contents = jsonData.ytInitialData{"contents"}

  if microformat.isNil:
    self.status.error = ExtractError.NotExist
    return false

  self.status.lastUpdate = now()

  try:
    self.title = microformat{"title", "simpleText"}.getStr
    self.description = microformat{"description", "simpleText"}.getStr
    block thumbnail:
      for thumb in videoDetails{"thumbnail", "thumbnails"}:
        self.thumbnails.add UrlAndSize(
          url: thumb{"url"}.getStr,
          width: thumb{"width"}.getInt,
          height: thumb{"height"}.getInt,
        )
    block embed:
      let data = microformat{"embed"}
      self.embed.url = data{"iframeUrl"}.getStr
      self.embed.width = data{"width"}.getInt
      self.embed.height = data{"height"}.getInt
    self.publishDate = times.parse(microformat{"publishDate"}.getStr, "yyyy-MM-dd")
    self.uploadDate = times.parse(microformat{"uploadDate"}.getStr, "yyyy-MM-dd")
    self.length =
      initDuration(seconds = microformat{"lengthSeconds"}.getStr.parseInt)
    self.views = microformat{"viewCount"}.getStr.parseInt
    self.familyFriendly = microformat{"isFamilySafe"}.getBool
    self.unlisted = microformat{"isUnlisted"}.getBool
    self.category = microformat{"category"}.getStr.parseCategory
    block channel:
      self.channel.id = microformat{"ownerProfileUrl"}.getStr.channelId
      self.channel.name = microformat{"ownerChannelName"}.getStr

      let subs = contents{"twoColumnWatchNextResults", "results", "results",
                          "contents"}.
        findInJson("videoSecondaryInfoRenderer"){"owner", "videoOwnerRenderer",
            "subscriberCountText", "simpleText"}.
          getStr.parseSubs

      if subs.len == 0:
        self.channel.hiddenSubscribers = true
      else:
        self.channel.subscribers = subs.parseInt

      block channelIcons:
        for icon in contents{"twoColumnWatchNextResults", "results", "results",
                            "contents"}.
          findInJson("videoSecondaryInfoRenderer"){"owner", "videoOwnerRenderer",
              "thumbnail", "thumbnails"}:
          self.channel.icons.add UrlAndSize(
            url: icon{"url"}.getStr,
            width: icon{"width"}.getInt,
            height: icon{"height"}.getInt,
          )

    block likes:
      let data = contents{"twoColumnWatchNextResults", "results", "results",
                          "contents"}.
        findInJson("videoPrimaryInfoRenderer"){"videoActions", "menuRenderer",
            "topLevelButtons"}
      proc get(data: JsonNode; i: int): int {.inline.} =
        data{i}{"toggleButtonRenderer", "defaultText", "accessibility",
                "accessibilityData", "label"}.
          getStr.multiReplace({
            ",": "",
            " likes": "",
            " dislikes": "",
            "No dislikes": "0",
            "No likes": "0"
          }).parseInt
      self.likes = data.get 0
      self.dislikes = data.get 1

    block keywords:
      if videoDetails.hasKey "keywords":
        for keyword in videoDetails{"keywords"}:
          self.keywords.add keyword.getStr

    self.private = videoDetails{"isPrivate"}.getBool
    self.live = videoDetails{"isLiveContent"}.getBool

    self.status.error = ExtractError.None
  except:
    self.status.error = ExtractError.ParseError
    # doAssert false, getCurrentExceptionMsg()
    return false


proc videoId*(url: string): YoutubeVideoId =
  ## Parses the video ID from url
  ## If gave a code instead url, it will return itself
  runnableExamples:
    doAssert $"https://www.youtube.com/watch?v=jjEQ-yKVPMg".videoId == "jjEQ-yKVPMg"
    doAssert $"jjEQ-yKVPMg".videoId == "jjEQ-yKVPMg"
  var id = ""
  block:
    const
      startIndexFinder = "v="
      endIndexFinder = "&"
    var startIndex = url.find startIndexFinder
    if startIndex > -1:
      inc startIndex, startIndexFinder.len
    else:
      id = url
      break

    var endIndex = startIndex + url[startIndex..^1].find endIndexFinder
    if endIndex == startIndex - 1:
      endIndex = url.len - 1
    id = url[startIndex..endIndex]
  result = id.strip.YoutubeVideoId

proc valid*(id: YoutubeVideoId): bool =
  ## Checks if this `YoutubeVideoId` instance is a valid youtube id
  ##
  ## Currently is just checking the length, but later will be added more checks
  runnableExamples:
    doAssert "invalid".YoutubeVideoId.valid == false
    doAssert "   Dx4eelwPGaQ".YoutubeVideoId.valid == false
    doAssert "Dx4eelwPGaQ".YoutubeVideoId.valid
  proc check(id: string): bool =
    result = true
    if id.len != 11: return false

  let strId = $id
  result = check(strId) and
           check(strId.strip)


proc extractVideo*(url: string; proxy = ""): YoutubeVideo =
  ## Extract all data from youtube video.
  ##
  ## `url` can be the video URL or id
  ##
  ## Just an alias of:
  ##
  ## .. code-block:: nim
  ##   var vid = initYoutubeVideo("jjEQ-yKVPMg".videoId)
  ##   discard vid.update():
  ## **Example:**
  ##
  ## .. code-block:: nim
  ##   var vid = extractVideo("jjEQ-yKVPMg")
  ##   echo vid
  result = initYoutubeVideo(url.videoId)
  discard result.update(proxy)
