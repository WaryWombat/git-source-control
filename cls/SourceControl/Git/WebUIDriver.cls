Class SourceControl.Git.WebUIDriver
{

ClassMethod HandleRequest(pagePath As %String, InternalName As %String = "", Output handled As %Boolean = 0, Output %data As %Stream.Object)
{
    set context = ##class(SourceControl.Git.PackageManagerContext).ForInternalName(InternalName)
    kill %data
    #dim %response as %CSP.Response
    #dim %request as %CSP.Request
    set pathStart = $piece(pagePath,"/",2)
    if pathStart = "api" {
        set handled = 1
        set %data = ##class(%Stream.FileCharacter).%New()
        if $extract(pagePath,6,*) = "userinfo" {
            set responseJSON = ..UserInfo()
        } elseif $extract(pagePath,6,*) = "uncommitted" {
            set responseJSON = ..Uncommitted()
        } elseif $extract(pagePath,6,*) = "settings" {
            set responseJSON = ..GetSettingsURL(%request)
        } else {
            set %response.Status = ##class(%CSP.REST).#HTTP404NOTFOUND
            set responseJSON = {"error":("invalid URI: " _ pagePath)}
        }
        if $isobject($get(responseJSON)) {
            do responseJSON.%ToJSON(%data)
        }
    } elseif $match(pathStart,"git|dirname|hostname|viewonly") {
        if (%request.Method = "GET") {
            set %data = ##class(%Stream.TmpCharacter).%New()
            // Things not handled from Python backend:
            /*
            def do_GET(self):
            elif self.is_git_request():
            self.process_http_backend()
            else:
            SimpleHTTPRequestHandler.do_GET(self)
            */
            if (pathStart = "git") {
                if $piece(pagePath,"/",3) = "cat-file" {
                    set file = $piece(pagePath,"/",4,*)
                    do ##class(SourceControl.Git.Utils).RunGitCommand("-c",,.%data,"color.ui=false","cat-file","-p",file)
                    do ##class(SourceControl.Git.Change).RefreshUncommitted()
                    set handled = 1
                }
            } elseif (pathStart = "hostname") {
                do %data.Write(##class(%SYS.System).GetNodeName())
                set handled = 1
            } elseif (pathStart = "viewonly") {
                // Never view-only
                do %data.Write(0)
                set handled = 1
            } elseif (pathStart = "dirname") {
                do %data.Write(##class(SourceControl.Git.Utils).TempFolder())
                set handled = 1
            }
        } elseif (%request.Method = "POST") {
            // Things not handled from Python backend:
            /*
            elif self.is_git_request():
            self.process_http_backend()
            else:
            SimpleHTTPRequestHandler.do_POST(self)
            */
            if (pathStart = "git") {
                set reference = "%request.Data"
                for {
                    set reference = $query(@reference)
                    quit:reference=""
                    if $qsubscript(reference,3)="O" {
                        set args(@reference)=$qsubscript(reference,1)
                        if $data(%request.Data($qsubscript(reference,1),$qsubscript(reference,2)),argValue)#2 && (argValue '= "") {
                            set args(@reference)=args(@reference)_"="_argValue
                        }
                    }
                }
                
                // Problem: args(1) might contain $c(10) followed by our stdin value
                if $data(args(1))#2 {
                    set stdin = $piece(args(1),$char(10),2,*)
                    set args(1) = $piece(args(1),$char(10))
                }

                set gitArgs($increment(gitArgs)) = "color.ui=true"

                // TODO: Don't be lazy! Implement shlex.split in ObjectScript.
                // The below is just a little bit cheesy.
                set argList = $listfromstring(args(1)," ")
                set pointer = 0
                set inQuotedString = 0
                while $listnext(argList,pointer,arg) {
                    set argStartsQuotedString = ($extract(arg) = """")
                    set argEndsQuotedString = ($extract(arg,*) = """")
                    if (inQuotedString) {
                        set inQuotedString = 'argEndsQuotedString
                        set gitArgs(gitArgs) = gitArgs(gitArgs)_" "_$extract(arg,1,*-argEndsQuotedString)
                    } elseif (arg '= "") {
                        set gitArgs($increment(gitArgs)) = $extract(arg,1+argStartsQuotedString,*-argEndsQuotedString)
                        set inQuotedString = argStartsQuotedString && 'argEndsQuotedString
                    }
                }

                // Do we have stdin?
                if (stdin '= "") {
                    set inStream = ##class(%Stream.FileCharacter).%New()
                    set inLines = $listfromstring(stdin,$char(10))
                    set pointer = 0
                    while $listnext(inLines,pointer,line) {
                        do inStream.WriteLine(line)
                    }
                    $$$ThrowOnError(inStream.%Save())
                    set inFile = inStream.Filename
                    set inStream.RemoveOnClose = 1
                } else {
                    set inFile = ""
                }
                set returnCode = ##class(SourceControl.Git.Utils).RunGitCommandWithInput("-c",inFile,.errStream,.outStream,gitArgs...)

                set %data = ##class(%Stream.TmpCharacter).%New()
                set changeTerminators = (%data.LineTerminator '= $char(13,10))
                set %data.LineTerminator = $char(13,10) // For the CSPGateway.
                while 'outStream.AtEnd {
                    do %data.WriteLine(outStream.ReadLine())
                }

                set nLines = 0
                while 'errStream.AtEnd {
                    do %data.WriteLine(errStream.ReadLine())
                    set:changeTerminators nLines = nLines + 1
                }
                
                // Need to write out two lines or we get an infinite loop in JavaScript...
                do %data.WriteLine()
                do %data.WriteLine()
                do %data.WriteLine("Git-Stderr-Length: " _ (errStream.Size + nLines))
                do %data.Write("Git-Return-Code: " _ returnCode) // No ending newline expected
                do %data.Rewind()
                do ##class(SourceControl.Git.Change).RefreshUncommitted()
                set handled = 1
            }
        }

    }
}

ClassMethod UserInfo() As %SystemBase
{
    quit {
        "name": (##class(SourceControl.Git.Utils).GitUserName()),
        "email": (##class(SourceControl.Git.Utils).GitUserEmail())
    }
}

ClassMethod Uncommitted() As %SystemBase
{
    // Stub
    do ##class(SourceControl.Git.Change).RefreshUncommitted()
    do ##class(SourceControl.Git.Utils).GitStatus(.files, 1)
    set output = ""
    set key = ""

    set array = []
    set key = ""
    for {
        set key = $order(files(key),1,fileData)
        quit:key=""
        // Check that current user has files(key) uncommitted and only %Push if they do
        set filename = ##class(Utils).FullExternalName(key)
        if (($ISVALIDNUM(key)) && (files(key) '= "")){
            do array.%Push($listget(fileData,2))
        }
        else{
            set sc=##class(SourceControl.Git.Change).GetUncommitted(filename,.tAction,.tInternalName,.UncommittedUser,.tSource,.UncommittedLastUpdated)
            if ($$$ISOK(sc)) && ($data(tAction)&&(UncommittedUser=$username)) {
                do array.%Push($listget(fileData,2))
            }
        }
    }
    quit array
}

ClassMethod GetURLPrefix(%request As %CSP.Request, URL As %String) As %String
{
    set appBasePath = "/isc/studio/usertemplates/gitsourcecontrol/"
    set locationOfAppPath = $LOCATE(%request.URL, appBasePath)

    if (locationOfAppPath > 1) {
        set beforeAppPath = $EXTRACT(%request.URL, 1, (locationOfAppPath-1))
        set URL = beforeAppPath_URL
    }
    quit URL
}

ClassMethod GetSettingsURL(%request As %CSP.Request) As %SystemBase
{
    set settingsURL = "/isc/studio/usertemplates/gitsourcecontrol/gitprojectsettings.csp?CSPSHARE=1&NSpace="_$namespace_"&Username="_$username
    set settingsURL = ..GetURLPrefix(%request, settingsURL)
    quit {"url": (settingsURL)}
}

}
