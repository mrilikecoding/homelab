FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
COPY refresh.sh /refresh.sh
RUN chmod +x /refresh.sh
EXPOSE 80
