
# Library -----------------------------------------------------------------

library(httr)
library(tidyverse)
library(lubridate)
library(googlesheets4)

# Collecting --------------------------------------------------------------

# deaths that happenened in Brazil from Covid-19
# from 01/01/2020 to 30/04/2020, grouped by age (10 years group) and gender.
# "https://transparencia.registrocivil.org.br/api/covid?data_type=data_ocorrido&start_date=2020-01-01&end_date=2020-04-30&state=Todos&search=death-covid&groupBy=gender"
# but, for now we need a token to request the data

# getting the needed token
# login
login_url <- "https://transparencia.registrocivil.org.br/registral-covid"
# Start with a fresh handle
h <- curl::new_handle()
# Ask server
request <- curl::curl_fetch_memory(login_url, handle = h)
# https://cran.r-project.org/web/packages/curl/vignettes/intro.html#reading_cookies
cookies <- curl::handle_cookies(h)
# we need the "XRSF-TOKEN"
token <- cookies$value[which(cookies$name == "XSRF-TOKEN")]
# if this don't succed need to get it manually
token <- "eyJpdiI6ImZNMXc3TDM5Z2JxQUl6NXVFWTFHOVE9PSIsInZhbHVlIjoiUk5wQU13blA1MUI0bW5BWTR0THVQUGpvWHBEYVpwMEpvN040SGlabEdsQ2pRRFZ4aGtYOG9Yb1R0S1F5dzZFbyIsIm1hYyI6ImZkNTg1MjRhYWRmMzZkMTE5MjI1NjI3ZDJhODBhMjQwNTg2OWFlODEyNDZhNmZmZjg5NjY2YWU1YTZhYzAwZmIifQ=="
# so, we need to iterate through only dates to get our data:
# number of daily deaths by gender and age group (10 years) 
# since the first death in Brazil
current_day <- Sys.Date()
dates <- seq.Date(dmy("16/03/2020"), current_day, by = "day")

# curl into httr:
# https://curl.trillworks.com/#r
headers <- c(
  `X-XSRF-TOKEN` = token,
  # dont know if it is a private info
  `User-Agent` = # Your User-Agent
)

list_date <- list()
list_age <- list()
list_gender <- list()
list_death <- list()

df <- tibble()

for(i in 1:length(dates)) {
  
  # curl into httr
  # https://curl.trillworks.com/#r
  params <- list(
    `chart` = 'chartEspecial4',
    `data_type` = 'data_ocorrido',
    # we retrieving data day by day
    `start_date` = dates[i],
    `end_date` = dates[i],
    `state` = 'Todos',
    `search` = 'death-covid',
    `groupBy` = 'gender'
  )
  
  response <- httr::GET(url = 'https://transparencia.registrocivil.org.br/api/covid', 
                        httr::add_headers(.headers=headers), 
                        query = params)
  
  raw_data <- httr::content(response)
  age_groups <- names(raw_data["chart"][[1]])

  for(j in 1:length(age_groups)) {
    
    genders <- names(raw_data["chart"][[1]][[j]])
      
    if(length(genders) != 0) {
      for(k in 1:length(genders)) {
        list_date <- append(list_date, dates[i])
        list_age <- append(list_age, age_groups[j])
        list_gender <- append(list_gender, genders[k])
        
        # j: age group
        # k: gender F or M
        deaths <- raw_data["chart"][[1]][j][[1]][[k]]
        list_death <- append(list_death, deaths)
      }
    } 
  }
  
  df_temp <- tibble(list_date, list_age, list_gender, list_death) %>% 
    unnest()
    
  list_date <- list()
  list_age <- list()
  list_gender <- list()
  list_death <- list()
  
  df <- df %>% 
    bind_rows(df_temp)
  
  # Pause for 0.1 seconds
  Sys.sleep(2)
  
  cat("i: ", i, " j: ", j, "\n")
}

# All combinations dataset ------------------------------------------------

df_combinations <- purrr::cross_df(
  .l = list(
    "Date" = df %>% select(list_date) %>% unique() %>% pull(),
    "Sex" = df %>% select(list_gender) %>% unique() %>% pull(),
    "Age" = df %>% select(list_age) %>% unique() %>% pull())
)

df_combinations <- df_combinations %>% 
  mutate(Date = lubridate::as_date(Date))

# Output ------------------------------------------------------------------

# daily deaths
df_output <- df_combinations %>% 
  left_join(df, by = c("Date" = "list_date", 
                       "Age" = "list_age", 
                       "Sex" = "list_gender")) %>% 
  mutate(Value = ifelse(is.na(list_death), 0, list_death)) %>% 
  select(-list_death)

# treating cases reported with gender 'I'  (ignored)
# create a category 'B' (both genders) that includes
# 'F', 'M', and 'I'
df_output <- df_output %>% 
  filter(Sex != "I") %>% 
  bind_rows(
    df_output %>%
      group_by(Date, Age) %>% 
      summarise(Value = sum(Value)) %>% 
      mutate(Sex = "B") %>% 
      ungroup()
    )

# daily deaths accumulated
df_output_accumulated <-  df_output %>%
  arrange(Sex, Age, Date) %>% 
  group_by(Sex, Age) %>% 
  mutate(Value_accumulated = cumsum(Value))

# Fixing columns ----------------------------------------------------------

# daily deaths
df_output <- df_output %>% 
  mutate(Age = case_when(
    Age == "< 9" ~ "0",
    Age == "> 100" ~ "100",
    TRUE ~ str_extract(Age, pattern = "^\\d{2}"))
  ) %>% 
  mutate(Age = as.integer(Age)) %>% 
  arrange(Date, Sex, Age) %>% 
  separate(col = Date, into = c("year", "month", "day"), sep = "-", remove = FALSE) %>% 
  unite(col = Date, ... = c("day", "month", "year"), sep = ".", remove = TRUE) %>% 
  mutate(Sex = case_when(
    Sex == "F" ~ "f",
    Sex == "M" ~ "m",
    Sex == "B" ~ "b")) %>% 
  mutate(Country = "Brazil",
         Region = "All",
         AgeInt = ifelse(Age == "100", 5, 10),
         Metric = "Count",
         Measure = "Deaths",
         Code = paste0("BR", Date))

df_output <- df_output %>% 
  select(Country, Region, Code, Date,
         Sex, Age, AgeInt, Metric, Measure,
         Value)

# daily deaths accumulated
df_output_accumulated <- df_output_accumulated %>% 
  ungroup() %>% 
  mutate(Age = case_when(
    Age == "< 9" ~ "0",
    Age == "> 100" ~ "100",
    TRUE ~ str_extract(Age, pattern = "^\\d{2}"))
  ) %>% 
  mutate(Age = as.integer(Age)) %>% 
  arrange(Date, Sex, Age) %>% 
  separate(col = Date, into = c("year", "month", "day"), sep = "-", remove = FALSE) %>% 
  unite(col = Date, ... = c("day", "month", "year"), sep = ".", remove = TRUE) %>% 
  mutate(Sex = case_when(
    Sex == "F" ~ "f",
    Sex == "M" ~ "m",
    Sex == "B" ~ "b")) %>% 
  mutate(Country = "Brazil",
         Region = "All",
         AgeInt = ifelse(Age == "100", 5, 10),
         Metric = "Count",
         Measure = "Deaths",
         Code = paste0("BR", Date))

df_output_accumulated <- df_output_accumulated %>% 
  select(Country, Region, Code, Date,
         Sex, Age, AgeInt, Metric, Measure,
         Value = Value_accumulated)

# Writing -----------------------------------------------------------------

# daily deaths
write.csv(df_output, file = paste0("./data/treated/deaths_br_", 
                            paste(rev(str_split(current_day, pattern = "-")[[1]]), collapse = "_"), 
                            "_covid_project.csv") , 
          row.names = FALSE)

# daily deaths accumulated
write.csv(df_output_accumulated, file = paste0("./data/treated/deaths_br_", 
                                   paste(rev(str_split(current_day, pattern = "-")[[1]]), collapse = "_"), 
                                   "_covid_project_accumulated.csv") , 
          row.names = FALSE)

# writing in google sheets
sheet_write(df_output_accumulated, 
            ss = "https://docs.google.com/spreadsheets/d/17w6gadj-nwtDFP6dmAkkMwd4lDEKD9Iqf6R0qeftvQc/edit", 
            sheet = "database")
