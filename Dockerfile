# syntax=docker/dockerfile:1
#
# Photo Sync 的上手指南站 (single-page static site)。
#
# 頁面`完全自足`: 截圖以 data URI 內嵌在 HTML 裡, 唯一的外部資源是 Google Fonts。
# 所以這顆 image 就是「一份 HTML + 一個 nginx」, 沒有 build step, 沒有執行期狀態,
# 也不需要任何環境變數或 bind mount——重建它的唯一理由是 web/ 的內容變了。
#
# 內容`烤進 image`而不是像 fun 那樣 bind mount host checkout: 這一頁是隨版本
# 一起演進的產品文件, image tag 因此能誠實回答「線上那份是哪一版的說明」。
ARG NGINX_VERSION=1.29-alpine

FROM nginx:${NGINX_VERSION}

# 上游 image 內建的 default.conf 是 listen 80 的示範站, 這裡整份取代掉:
# 曝光面由 compose 的 ports: 決定, 容器裡不該留一個沒人轉發得到的 server。
COPY web/nginx.conf /etc/nginx/conf.d/default.conf
# 逐檔 COPY 而不是 COPY web/ : nginx.conf 與網頁內容住在同一個目錄,
# 整包複製會把設定檔一起送進 web root 對外端出去。
COPY web/index.html /usr/share/nginx/html/index.html

EXPOSE 8321
