; Registrácia Vimeo Viewer ako prehliadača, aby sa dal vybrať v Nastavenia → Predvolené aplikácie.
; Vimeo odkazy potom otvára aplikácia, ostatné odkazy prepošle do pôvodného prehliadača.
!macro customInstall
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\VimeoViewer" "" "Vimeo Viewer"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\VimeoViewer\Capabilities" "ApplicationName" "Vimeo Viewer"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\VimeoViewer\Capabilities" "ApplicationDescription" "Otvára odkazy na Vimeo, ostatné posiela do vášho prehliadača"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\VimeoViewer\Capabilities" "ApplicationIcon" "$INSTDIR\${APP_EXECUTABLE_FILENAME},0"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\VimeoViewer\Capabilities\URLAssociations" "http" "VimeoViewerURL"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\VimeoViewer\Capabilities\URLAssociations" "https" "VimeoViewerURL"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\VimeoViewer\DefaultIcon" "" "$INSTDIR\${APP_EXECUTABLE_FILENAME},0"
  WriteRegStr HKCU "Software\Clients\StartMenuInternet\VimeoViewer\shell\open\command" "" '"$INSTDIR\${APP_EXECUTABLE_FILENAME}"'
  WriteRegStr HKCU "Software\Classes\VimeoViewerURL" "" "Vimeo Viewer URL"
  WriteRegStr HKCU "Software\Classes\VimeoViewerURL" "URL Protocol" ""
  WriteRegStr HKCU "Software\Classes\VimeoViewerURL\DefaultIcon" "" "$INSTDIR\${APP_EXECUTABLE_FILENAME},0"
  WriteRegStr HKCU "Software\Classes\VimeoViewerURL\shell\open\command" "" '"$INSTDIR\${APP_EXECUTABLE_FILENAME}" "%1"'
  WriteRegStr HKCU "Software\RegisteredApplications" "VimeoViewer" "Software\Clients\StartMenuInternet\VimeoViewer\Capabilities"
!macroend

!macro customUnInstall
  DeleteRegKey HKCU "Software\Clients\StartMenuInternet\VimeoViewer"
  DeleteRegKey HKCU "Software\Classes\VimeoViewerURL"
  DeleteRegValue HKCU "Software\RegisteredApplications" "VimeoViewer"
!macroend
